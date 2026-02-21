use crate::csv_parser;
use crate::json_parser;
use crate::processor::ParsedData;

use std::collections::HashMap;

/// Supported input formats.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Format {
    Json,
    Csv,
    KeyValueConfig,
}

/// Detect the format of `content` by inspecting its first non-blank line.
///
/// Heuristics:
/// - Starts with `[`  -> JSON array
/// - Contains a comma on the first data line -> CSV
/// - Otherwise        -> key-value config
pub fn detect_format(content: &str) -> Format {
    let first_line = content
        .lines()
        .map(|l| l.trim())
        .find(|l| !l.is_empty())
        .unwrap_or("");

    if first_line.starts_with('[') {
        return Format::Json;
    }

    if first_line.contains(',') {
        return Format::Csv;
    }

    Format::KeyValueConfig
}

/// Route content to the appropriate parser.
pub fn parse(content: &str) -> ParsedData {
    let format = detect_format(content);

    match format {
        Format::Json => {
            match json_parser::parse_json(content) {
                Ok(data) => data,
                Err(_) => {
                    // JSON parse failed — fall through to CSV as a guess.
                    csv_parser::parse_csv(content).expect("CSV parse also failed")
                }
            }
        }
        Format::Csv => {
            csv_parser::parse_csv(content).expect("CSV parse failed")
        }
        Format::KeyValueConfig => {
            parse_key_value_config(content)
        }
    }
}

/// Parse an INI-style key-value configuration file.
///
/// Supports `[section]` headers.  Keys within a section are stored as
/// `section.key` in the resulting map.
fn parse_key_value_config(content: &str) -> ParsedData {
    let mut map = HashMap::new();
    let mut current_section = String::new();

    for line in content.lines() {
        let line = line.trim();

        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }

        // Section header: [name]
        if line.starts_with('[') && line.ends_with(']') {
            current_section = line[1..line.len() - 1].trim().to_string();
            continue;
        }

        // Key = value pair
        if let Some(eq_pos) = line.find('=') {
            let key = line[..eq_pos].trim();
            let value = line[eq_pos + 1..].trim();

            let full_key = if current_section.is_empty() {
                key.to_string()
            } else {
                format!("{}.{}", current_section, key)
            };

            map.insert(full_key, value.to_string());
        }
    }

    ParsedData::Config(map)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_csv() {
        assert_eq!(detect_format("name,age,city\nAlice,30,NYC"), Format::Csv);
    }

    #[test]
    fn detect_json() {
        assert_eq!(
            detect_format("[{\"a\":1},{\"b\":2}]"),
            Format::Json
        );
    }

}
