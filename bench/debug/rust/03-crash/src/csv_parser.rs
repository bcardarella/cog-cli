use crate::processor::ParsedData;

/// Parse CSV content (comma-separated values with a header row).
///
/// The first non-empty line is treated as the header.  Subsequent
/// lines are data rows.  Each field is parsed by splitting on commas
/// and trimming whitespace.
///
/// # Panics
///
/// Panics (via `.unwrap()`) if any data row has a different number of
/// fields than the header.
pub fn parse_csv(content: &str) -> Result<ParsedData, String> {
    let lines: Vec<&str> = content
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect();

    if lines.is_empty() {
        return Err("Empty CSV content".into());
    }

    let headers: Vec<String> = lines[0]
        .split(',')
        .map(|h| h.trim().to_string())
        .collect();

    let num_cols = headers.len();
    let mut rows: Vec<Vec<String>> = Vec::new();

    for (line_no, &line) in lines[1..].iter().enumerate() {
        let fields: Vec<String> = line
            .split(',')
            .map(|f| f.trim().to_string())
            .collect();

        // Validate that every row has exactly the right number of columns.
        let valid = (fields.len() == num_cols)
            .then_some(())
            .ok_or_else(|| {
                format!(
                    "Row {} has {} fields, expected {} (line: {:?})",
                    line_no + 2,
                    fields.len(),
                    num_cols,
                    line
                )
            });

        valid.unwrap();

        rows.push(fields);
    }

    Ok(ParsedData::CsvTable { headers, rows })
}
