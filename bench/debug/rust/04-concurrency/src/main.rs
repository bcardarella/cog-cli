mod worker;
mod stage;
mod pipeline;

use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use worker::{check_completeness, validate_batch};

/// Run the pipeline with a timeout.
///
/// If the pipeline completes within the timeout, print a summary of the
/// results.  If it hangs, print an error and exit.
fn main() {
    let (result_tx, result_rx) = mpsc::channel();

    let handle = thread::spawn(move || {
        let results = pipeline::run_pipeline();
        let _ = result_tx.send(results);
    });

    // Wait up to 5 seconds.
    match result_rx.recv_timeout(Duration::from_secs(5)) {
        Ok(results) => {
            report_results(&results);
        }
        Err(mpsc::RecvTimeoutError::Timeout) => {
            eprintln!("ERROR: Pipeline timed out after 5s");
            std::process::exit(1);
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            eprintln!("ERROR: Pipeline thread disconnected unexpectedly");
            std::process::exit(1);
        }
    }

    // Join if we got a result.
    let _ = handle.join();
}

/// Print a summary of the pipeline output.
fn report_results(results: &[worker::Record]) {
    println!("Processed {} records", results.len());

    // Integrity check.
    let (valid, invalid_ids) = validate_batch(results);
    if !invalid_ids.is_empty() {
        eprintln!(
            "WARNING: {} records failed integrity check: {:?}",
            invalid_ids.len(),
            &invalid_ids[..invalid_ids.len().min(10)]
        );
    } else {
        eprintln!("All {} records passed integrity check", valid);
    }

    // Completeness check.
    let (missing, duplicates) = check_completeness(results, 500);
    if !missing.is_empty() {
        eprintln!(
            "WARNING: {} missing record ids: {:?}",
            missing.len(),
            &missing[..missing.len().min(10)]
        );
    }
    if !duplicates.is_empty() {
        eprintln!(
            "WARNING: {} duplicate record ids: {:?}",
            duplicates.len(),
            &duplicates[..duplicates.len().min(10)]
        );
    }
}
