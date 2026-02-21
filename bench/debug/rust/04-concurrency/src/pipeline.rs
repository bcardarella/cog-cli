use std::sync::mpsc::sync_channel;
use std::thread;

use crate::stage;
use crate::worker::Record;

/// Channel buffer size.
const CHANNEL_BOUND: usize = 5;

/// Total records to push through the pipeline.
const NUM_RECORDS: u32 = 500;

/// Configuration for the pipeline (extracted for clarity).
struct PipelineConfig {
    num_records: u32,
    channel_bound: usize,
}

impl Default for PipelineConfig {
    fn default() -> Self {
        PipelineConfig {
            num_records: NUM_RECORDS,
            channel_bound: CHANNEL_BOUND,
        }
    }
}

/// Build and run the 3-stage pipeline, returning collected results.
///
/// The pipeline topology:
///
/// ```text
///   producer --> [input] --> Stage 1 --> [s1_to_s2] --> Stage 2 --> [s2_to_s3] --> Stage 3 --> results
///                                ^                         |
///                                |--- [feedback] ----------|
/// ```
///
/// All channels are `sync_channel` with a small bound.
pub fn run_pipeline() -> Vec<Record> {
    let config = PipelineConfig::default();
    let bound = config.channel_bound;

    // Forward channels (bounded).
    let (input_tx, input_rx) = sync_channel::<Record>(bound);
    let (s1_to_s2_tx, s1_to_s2_rx) = sync_channel::<Record>(bound);
    let (s2_to_s3_tx, s2_to_s3_rx) = sync_channel::<Record>(bound);

    // Feedback channel (bounded).
    let (feedback_tx, feedback_rx) = sync_channel::<Record>(bound);

    // --- Spawn pipeline stages ---

    let s1 = thread::Builder::new()
        .name("stage-1".into())
        .spawn(move || {
            stage::stage1(input_rx, s1_to_s2_tx, feedback_rx);
        })
        .expect("failed to spawn stage 1");

    let s2 = thread::Builder::new()
        .name("stage-2".into())
        .spawn(move || {
            stage::stage2(s1_to_s2_rx, s2_to_s3_tx, feedback_tx);
        })
        .expect("failed to spawn stage 2");

    let s3 = thread::Builder::new()
        .name("stage-3".into())
        .spawn(move || -> Vec<Record> {
            stage::stage3(s2_to_s3_rx)
        })
        .expect("failed to spawn stage 3");

    // --- Producer: feed records into Stage 1 ---
    for i in 1..=config.num_records {
        let record = Record::new(i);
        input_tx.send(record).expect("producer send failed");
    }
    drop(input_tx); // close the input channel to signal EOF

    // --- Wait for the pipeline to complete ---
    s1.join().expect("stage 1 panicked");
    s2.join().expect("stage 2 panicked");
    let results = s3.join().expect("stage 3 panicked");

    results
}
