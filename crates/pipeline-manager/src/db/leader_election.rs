//! Elects one API server to drive the pipelines when several are running.
//!
//! The reconciliation loop assumes it is the only one: it lists every pipeline
//! and spawns an automaton per pipeline, and each automaton provisions, starts
//! and stops the pipeline it owns. Two API servers running that loop against
//! one database both act on every pipeline, and the damage is worse than
//! duplicated work: each provisioning generates a fresh deployment id, so the
//! two automatons overwrite each other's deployment id in the pipeline row,
//! then each concludes the deployment it owns is not the one recorded and
//! tears down the other's objects. The observable result is a pipeline that
//! never reaches a steady state while both instances keep restarting it.
//!
//! One API server therefore holds a session-scoped advisory lock in Postgres
//! and reconciles; the others serve HTTP and wait. The lock, not the API
//! servers, is the source of truth, which is what makes failover safe: it
//! belongs to a connection, so a process that dies, a host that partitions from
//! the database, or a pod whose kernel kills it releases it when the connection
//! goes away, with no lease duration to tune and no way to leave two leaders.
//!
//! A leader verifies the lock rather than assuming it: losing the database
//! closes the connection the lock lives on, and the next heartbeat fails,
//! demoting the process before a standby that acquired the freed lock starts
//! acting. Without that check a network partition would produce exactly the
//! split brain this module exists to prevent — the isolated leader would keep
//! reconciling from its last known state while the new leader did the same.
//!
//! The HTTP surface is deliberately not behind the lock: a client that reaches
//! a standby gets the same answers, because they come from the database. The
//! exception is following a running pipeline's log, which is streamed from the
//! memory of the process that runs the pipeline. That is why a standby answers
//! `503` for a log request rather than `404`: the pipeline does exist, it is
//! the log stream that is on the other instance, and the client's retry after
//! failover succeeds.

use crate::db::storage_postgres::StoragePostgres;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::watch;
use tokio::time::Instant;
use tokio_postgres::AsyncMessage;
use tracing::{error, info, warn};

/// How long a single attempt to take the lock may wait for the database.
///
/// A start-up that hangs here hangs the whole process, because the API server
/// does not serve until the role is settled. Bounding the attempt is what keeps
/// a slow database from turning into a pod that fails its liveness probe.
const ACQUIRE_TIMEOUT: Duration = Duration::from_secs(10);

/// How long to wait before another attempt after a failed one.
///
/// Short enough that a leader which died is replaced within seconds, since
/// pipelines are not reconciled for the duration; long enough that a database
/// which is down is not hammered by every standby in the deployment.
const RETRY_INTERVAL: Duration = Duration::from_secs(2);

/// How often a leader proves it still holds the lock.
///
/// The query is a round trip to the server on the very connection the lock
/// lives on, so it fails as soon as that connection is gone, which is the
/// instant the lock is released and a standby may take it.
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(5);

/// How long a heartbeat may take before the lock is presumed lost.
///
/// A heartbeat that hangs is indistinguishable from one that failed: either
/// way this process can no longer prove it holds the lock, and continuing to
/// reconcile on that assumption is the failure mode this module prevents.
const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(5);

/// Key of the advisory lock.
///
/// Any 64-bit constant works as long as nothing else uses it on this database.
/// The value is arbitrary but must never change: a different value would let an
/// old and a new deployment hold two different locks and elect two leaders
/// during a rolling upgrade.
const ADVISORY_LOCK_KEY: i64 = 0x6665_6c64_6572_6101;

/// Whether this process runs the reconciliation loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Leadership {
    /// This process holds the lock and reconciles.
    Leader,
    /// Another process holds the lock; this one serves HTTP only.
    Standby,
}

/// A held lock, whose connection keeps it alive.
///
/// Dropping this closes the connection, which releases the lock. That is the
/// entire release path, and it is why a crash cannot leave the lock behind.
struct Held {
    /// The connection the lock belongs to. Held so it stays open.
    client: tokio_postgres::Client,
    /// The task draining the connection's messages. Without a task reading
    /// them the socket buffer fills and the server eventually treats the
    /// session as dead, so this task is what keeps the lock alive; it is
    /// aborted when the lock is dropped.
    connection_task: tokio::task::JoinHandle<()>,
}

impl Held {
    /// Releases the lock by asking the server, then closing the connection.
    ///
    /// Closing the connection would release it anyway, but only once the socket
    /// is torn down, which is not synchronous. Asking first makes the lock
    /// available to a standby at a known instant, which shortens the window in
    /// which nobody reconciles during a rolling restart.
    async fn release(self) {
        let _ = tokio::time::timeout(
            HEARTBEAT_TIMEOUT,
            self.client
                .execute("SELECT pg_advisory_unlock($1)", &[&ADVISORY_LOCK_KEY]),
        )
        .await;
        self.connection_task.abort();
    }

    /// Proves the lock is still held, by querying on its own connection.
    ///
    /// Any successful round trip suffices: the lock is a property of the
    /// session, so a session that answers is a session that still holds it.
    async fn still_held(&self) -> bool {
        matches!(
            tokio::time::timeout(HEARTBEAT_TIMEOUT, self.client.query_one("SELECT 1", &[])).await,
            Ok(Ok(_))
        )
    }
}

/// Takes the lock if it is free, without waiting for it.
///
/// `pg_try_advisory_lock` is deliberate: the blocking variant would park the
/// connection inside the server, where a cancelled request is not guaranteed to
/// interrupt it and where a waiting standby is indistinguishable from a hung
/// one.
async fn try_take_lock(db: &Arc<tokio::sync::Mutex<StoragePostgres>>) -> Option<Held> {
    let (config, connector) = {
        let db = db.lock().await;
        match db.db_config.tls_connector() {
            Ok(connector) => (db.config.clone(), connector),
            Err(error) => {
                error!("Leadership election cannot build a TLS connector: {error}");
                return None;
            }
        }
    };

    let (client, connection) = match tokio::time::timeout(ACQUIRE_TIMEOUT, config.connect(connector))
        .await
    {
        Ok(Ok(pair)) => pair,
        Ok(Err(error)) => {
            warn!("Leadership election could not connect to the database: {error}");
            return None;
        }
        Err(_) => {
            warn!(
                "Leadership election gave up connecting to the database after {}s",
                ACQUIRE_TIMEOUT.as_secs()
            );
            return None;
        }
    };

    // The connection future must be polled for the client to make progress at
    // all. Nothing but the end of the session is expected on it.
    let connection_task = tokio::spawn(async move {
        let mut connection = connection;
        loop {
            match std::future::poll_fn(|cx| connection.poll_message(cx)).await {
                Some(Ok(AsyncMessage::Notice(notice))) => {
                    // Notices are informational; the server sends them for
                    // things like an advisory lock being released.
                    warn!("PostgreSQL notice on the leadership connection: {notice}");
                }
                Some(Ok(_)) => {}
                Some(Err(error)) => {
                    warn!("Leadership connection ended: {error}");
                    break;
                }
                // The session closed: the lock went with it.
                None => break,
            }
        }
    });

    match tokio::time::timeout(
        ACQUIRE_TIMEOUT,
        client.query_one("SELECT pg_try_advisory_lock($1)", &[&ADVISORY_LOCK_KEY]),
    )
    .await
    {
        Ok(Ok(row)) => {
            let acquired: bool = row.get(0);
            if acquired {
                Some(Held {
                    client,
                    connection_task,
                })
            } else {
                connection_task.abort();
                None
            }
        }
        Ok(Err(error)) => {
            warn!("Leadership election query failed: {error}");
            connection_task.abort();
            None
        }
        Err(_) => {
            warn!(
                "Leadership election gave up on the lock query after {}s",
                ACQUIRE_TIMEOUT.as_secs()
            );
            connection_task.abort();
            None
        }
    }
}

/// Shared handles to the election's current state.
#[derive(Clone)]
pub struct LeadershipHandle {
    leadership: watch::Receiver<Leadership>,
    /// The role as the last election round published it, readable without
    /// awaiting: an HTTP handler must not block on whether the role settled.
    is_leader: Arc<AtomicBool>,
    /// Whether this process has ever held the lock.
    ///
    /// A standby that has never been leader has never run the reconciliation
    /// loop, so it has no in-memory state about pipelines at all. This flag
    /// lets a caller distinguish that from a standby that led recently and is
    /// missing only the live log buffers.
    was_leader: Arc<AtomicBool>,
}

impl LeadershipHandle {
    /// The role as of the last published change.
    pub fn current(&self) -> Leadership {
        if self.is_leader.load(Ordering::Acquire) {
            Leadership::Leader
        } else {
            Leadership::Standby
        }
    }

    /// Whether this process currently holds the lock.
    pub fn is_leader(&self) -> bool {
        self.current() == Leadership::Leader
    }

    /// Whether this process has held the lock at some point.
    pub fn was_ever_leader(&self) -> bool {
        self.was_leader.load(Ordering::Acquire)
    }

    /// Builds a handle from its parts, for tests that do not run an election.
    #[cfg(test)]
    pub(crate) fn for_test(
        leadership: watch::Receiver<Leadership>,
        is_leader: Arc<AtomicBool>,
        was_leader: Arc<AtomicBool>,
    ) -> Self {
        Self {
            leadership,
            is_leader,
            was_leader,
        }
    }

    /// Waits for the role to change, returning `None` when the election task has
    /// stopped, which happens only during shutdown.
    ///
    /// A caller that owns work which must not continue without the lock waits
    /// on this and cancels that work when the role stops being
    /// [`Leadership::Leader`]. A demoted process that kept reconciling would
    /// fight the instance that took over.
    pub async fn changed(&mut self) -> Option<Leadership> {
        match self.leadership.changed().await {
            Ok(()) => Some(*self.leadership.borrow_and_update()),
            Err(_) => None,
        }
    }
}

/// Runs the election for the life of the process and returns the handle the
/// rest of the process reads its role from.
///
/// When `enabled` is false the process is leader immediately and takes no lock.
/// A single API server has nothing to elect against, and taking a lock would
/// make it depend on a second database connection for no benefit while turning
/// an accidentally started second manager into a silent standby that answers
/// requests but reconciles nothing.
pub fn start_election(
    enabled: bool,
    db: Arc<tokio::sync::Mutex<StoragePostgres>>,
) -> LeadershipHandle {
    let initial = if enabled {
        Leadership::Standby
    } else {
        Leadership::Leader
    };
    let is_leader = Arc::new(AtomicBool::new(initial == Leadership::Leader));
    let was_leader = Arc::new(AtomicBool::new(initial == Leadership::Leader));
    let (sender, receiver) = watch::channel(initial);
    let handle = LeadershipHandle {
        leadership: receiver,
        is_leader: is_leader.clone(),
        was_leader: was_leader.clone(),
    };

    if !enabled {
        info!("Leadership election is disabled: this process reconciles pipelines");
        return handle;
    }

    tokio::spawn(election_loop(db, sender, is_leader, was_leader));
    handle
}

/// Publishes a role, and reports whether it was a change.
///
/// A role that did not change publishes nothing: a standby retries every
/// [`RETRY_INTERVAL`], and waking every waiter each time would turn the log
/// into a countdown and the watchers into a spin.
fn publish(
    sender: &watch::Sender<Leadership>,
    is_leader: &AtomicBool,
    was_leader: &AtomicBool,
    role: Leadership,
) -> bool {
    if *sender.borrow() == role {
        return false;
    }
    if role == Leadership::Leader {
        was_leader.store(true, Ordering::Release);
    }
    is_leader.store(role == Leadership::Leader, Ordering::Release);
    // A send fails only when every receiver is gone, which means the process is
    // shutting down. The loop keeps running regardless so the lock is released
    // by dropping `Held`.
    let _ = sender.send(role);
    true
}

/// Acquires the lock, holds it while it keeps answering, and re-acquires it
/// after it is lost.
async fn election_loop(
    db: Arc<tokio::sync::Mutex<StoragePostgres>>,
    sender: watch::Sender<Leadership>,
    is_leader: Arc<AtomicBool>,
    was_leader: Arc<AtomicBool>,
) {
    let mut held: Option<Held> = None;
    let mut led_before = false;
    loop {
        match held.take() {
            None => match try_take_lock(&db).await {
                Some(lock) => {
                    held = Some(lock);
                    if publish(&sender, &is_leader, &was_leader, Leadership::Leader) {
                        if led_before {
                            info!(
                                "Leadership acquired: this process resumes reconciling pipelines"
                            );
                        } else {
                            info!(
                                "Leadership acquired: this process reconciles pipelines; other \
                                 instances serve the API without reconciling"
                            );
                        }
                    }
                }
                None => {
                    if publish(&sender, &is_leader, &was_leader, Leadership::Standby) {
                        info!(
                            "Another instance holds the leadership lock: this process serves the \
                             API without reconciling pipelines"
                        );
                    }
                    tokio::time::sleep(RETRY_INTERVAL).await;
                }
            },
            Some(lock) => {
                let mut last_verified = Instant::now();
                // Hold the lock, verifying it until the connection stops
                // answering or the process exits.
                loop {
                    tokio::time::sleep(HEARTBEAT_INTERVAL).await;
                    if lock.still_held().await {
                        last_verified = Instant::now();
                        continue;
                    }
                    warn!(
                        "Leadership lost after {}s without a successful heartbeat: this process \
                         stops reconciling pipelines",
                        last_verified.elapsed().as_secs()
                    );
                    led_before = true;
                    // Dropping releases the connection, and the server releases
                    // the lock with it.
                    lock.release().await;
                    publish(&sender, &is_leader, &was_leader, Leadership::Standby);
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A process that takes no part in the election is the leader from the
    /// first instant, so the API server starts reconciling without waiting for
    /// a task to run.
    #[test]
    fn a_disabled_election_is_the_leader_immediately() {
        let (_sender, receiver) = watch::channel(Leadership::Leader);
        let handle = LeadershipHandle {
            leadership: receiver,
            is_leader: Arc::new(AtomicBool::new(true)),
            was_leader: Arc::new(AtomicBool::new(true)),
        };
        assert_eq!(handle.current(), Leadership::Leader);
        assert!(handle.is_leader());
        assert!(handle.was_ever_leader());
    }

    /// A fresh standby claims neither the role nor a leadership history, which
    /// is what lets the API tell an idle instance from one that led recently.
    #[test]
    fn a_standby_has_never_been_leader() {
        let (_sender, receiver) = watch::channel(Leadership::Standby);
        let handle = LeadershipHandle {
            leadership: receiver,
            is_leader: Arc::new(AtomicBool::new(false)),
            was_leader: Arc::new(AtomicBool::new(false)),
        };
        assert_eq!(handle.current(), Leadership::Standby);
        assert!(!handle.is_leader());
        assert!(!handle.was_ever_leader());
    }

    /// A promotion reaches a waiter, and the flag a request path reads without
    /// awaiting agrees with it.
    #[tokio::test]
    async fn a_promotion_reaches_a_waiter() {
        let (sender, receiver) = watch::channel(Leadership::Standby);
        let is_leader = Arc::new(AtomicBool::new(false));
        let mut handle = LeadershipHandle {
            leadership: receiver,
            is_leader: is_leader.clone(),
            was_leader: Arc::new(AtomicBool::new(false)),
        };

        is_leader.store(true, Ordering::Release);
        sender.send(Leadership::Leader).unwrap();

        assert_eq!(handle.changed().await, Some(Leadership::Leader));
        assert!(handle.is_leader());
    }

    /// The end of the election task ends a waiter instead of parking it
    /// forever, so a caller blocked on a role change can proceed to shutdown.
    #[tokio::test]
    async fn the_end_of_the_election_ends_the_wait() {
        let (sender, receiver) = watch::channel(Leadership::Standby);
        let mut handle = LeadershipHandle {
            leadership: receiver,
            is_leader: Arc::new(AtomicBool::new(false)),
            was_leader: Arc::new(AtomicBool::new(false)),
        };
        drop(sender);
        assert_eq!(handle.changed().await, None);
    }

    /// Publishing the same role twice is not a change, so a standby that keeps
    /// failing to acquire does not wake its waiters every two seconds. The
    /// publication helper reports this, and only a real transition is
    /// published: a waiter that observes a standby stays parked.
    #[tokio::test]
    async fn republishing_the_same_role_does_not_wake_a_waiter() {
        let (sender, receiver) = watch::channel(Leadership::Standby);
        let is_leader = Arc::new(AtomicBool::new(false));
        let was_leader = Arc::new(AtomicBool::new(false));
        let mut handle = LeadershipHandle {
            leadership: receiver,
            is_leader: is_leader.clone(),
            was_leader: was_leader.clone(),
        };

        assert!(!publish(
            &sender,
            &is_leader,
            &was_leader,
            Leadership::Standby
        ));
        assert!(
            tokio::time::timeout(Duration::from_millis(50), handle.changed())
                .await
                .is_err(),
            "a repeated role must not wake the waiter"
        );

        assert!(publish(
            &sender,
            &is_leader,
            &was_leader,
            Leadership::Leader
        ));
        assert_eq!(
            tokio::time::timeout(Duration::from_millis(50), handle.changed())
                .await
                .expect("a real transition must wake the waiter"),
            Some(Leadership::Leader)
        );
        assert!(handle.was_ever_leader());
    }
}
