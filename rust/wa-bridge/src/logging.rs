//! `log` facade → Swift `LogSink`. `tracing` is built with its `log` feature, so tracing events
//! (from any crate in the graph, including whatsapp-rust's optional `tracing` feature) arrive here
//! as log records too: one logger forwards both.

use std::sync::{Arc, OnceLock, RwLock};

use crate::types::{LogLevel, LogSink};

struct SinkLogger {
    sink: RwLock<Arc<dyn LogSink>>,
}

static LOGGER: OnceLock<SinkLogger> = OnceLock::new();

fn to_filter(level: LogLevel) -> log::LevelFilter {
    let requested = match level {
        LogLevel::Error => log::LevelFilter::Error,
        LogLevel::Warn => log::LevelFilter::Warn,
        LogLevel::Info => log::LevelFilter::Info,
        LogLevel::Debug => log::LevelFilter::Debug,
        LogLevel::Trace => log::LevelFilter::Trace,
    };
    if cfg!(debug_assertions) { requested } else { requested.min(log::LevelFilter::Info) }
}

impl log::Log for SinkLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &log::Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let level = match record.level() {
            log::Level::Error => LogLevel::Error,
            log::Level::Warn => LogLevel::Warn,
            log::Level::Info => LogLevel::Info,
            log::Level::Debug => LogLevel::Debug,
            log::Level::Trace => LogLevel::Trace,
        };
        let sink = self.sink.read().unwrap().clone();
        sink.on_log(level, record.target().to_string(), record.args().to_string());
    }

    fn flush(&self) {}
}

/// Installs (or re-targets) the process-wide logger.
pub fn install(sink: Arc<dyn LogSink>, max_level: LogLevel) {
    let mut fresh = false;
    let logger = LOGGER.get_or_init(|| {
        fresh = true;
        SinkLogger { sink: RwLock::new(sink.clone()) }
    });
    if fresh {
        let _ = log::set_logger(logger);
    } else {
        *logger.sink.write().unwrap() = sink;
    }
    log::set_max_level(to_filter(max_level));
}
