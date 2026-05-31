pub const TARGET_SAMPLE_RATE: f64 = 16_000.0;

pub fn resample_to_16k(input: Vec<f32>, input_rate: f64) -> std::io::Result<Vec<f32>> {
    if input.is_empty() {
        return Ok(input);
    }
    if (input_rate - TARGET_SAMPLE_RATE).abs() < 1.0 {
        return Ok(input);
    }
    let output_len = ((input.len() as f64) * TARGET_SAMPLE_RATE / input_rate).ceil() as usize;
    let mut output = Vec::with_capacity(output_len);
    for index in 0..output_len {
        let src_index = (index as f64 * input_rate / TARGET_SAMPLE_RATE) as usize;
        let sample = input
            .get(src_index.min(input.len() - 1))
            .copied()
            .unwrap_or(0.0);
        output.push(sample);
    }
    Ok(output)
}
