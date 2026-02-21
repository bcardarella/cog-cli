mod processor;
mod parser;
mod json_parser;
mod csv_parser;

use processor::summarise;

/// Sample INI-style config input.
const INPUT: &str = "\
[metadata]
name = test_app
version = 1.0

[network]
allowed_hosts = alpha, beta
port = 8080
timeout = 30
";

fn main() {
    let data = parser::parse(INPUT);
    summarise(&data);
}
