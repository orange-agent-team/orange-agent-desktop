mod actor;
pub mod api;
mod host;
// Reviewed upstream FFI/codec assertions live only in generated glue. Handwritten
// Host code keeps deny(unsafe_code) and Clippy's unwrap check. Generation hashes
// and real native tests guard this boundary; no business logic belongs here.
#[allow(unsafe_code, clippy::unwrap_used)]
mod frb_generated;
