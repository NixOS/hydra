use std::collections::BTreeSet;

use harmonia_store_core::derivation::Derivation;
use harmonia_store_core::derived_path::{OutputName, SingleDerivedPath};
use harmonia_store_core::store_path::StorePath;

/// Output names of intermediate derivations for a dynamic derivation
/// dependency, stored in reverse order so that the next level to resolve
/// can be cheaply `pop()`-ed.
///
/// e.g. for a derivation input that is `aaaa-dyn.drv^foo^bar^out`, the final
/// derivation would be `aaaa-dyn.drv^foo^bar` (no final `^out`). The output
/// names are stored as `["bar", "foo"]` (reversed).
///
/// In the common case of depending on a static derivation, this is empty.
#[derive(Debug, Clone, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct OutputNameChain(pub Vec<OutputName>);

impl OutputNameChain {
    pub fn pop(&mut self) -> Option<OutputName> {
        self.0.pop()
    }
}

/// Flatten a [`SingleDerivedPath`] into `(root_drv_path, chain)`.
///
/// The output chain is in stack order (outermost first) matching
/// [`OutputNameChain`]'s convention. For `Built { Opaque(A), "foo" }`,
/// returns `(A, ["foo"])`. For `Opaque(A)`, returns `(A, [])`.
#[must_use]
pub fn flatten_path(sdp: &SingleDerivedPath) -> (StorePath, OutputNameChain) {
    match sdp {
        SingleDerivedPath::Opaque(p) => (p.clone(), OutputNameChain::default()),
        SingleDerivedPath::Built { drv_path, output } => flatten_chain(drv_path, output),
    }
}

/// Like [`flatten_path`] but appends an additional output name.
///
/// For `Built { Opaque(A), "foo" }` with output `"bar"`,
/// returns `(A, ["bar", "foo"])`.
#[must_use]
pub fn flatten_chain(
    drv_path: &SingleDerivedPath,
    output_name: &OutputName,
) -> (StorePath, OutputNameChain) {
    let (root, mut chain) = flatten_path(drv_path);
    chain.0.push(output_name.clone());
    (root, chain)
}

/// Extract `Built` input dependencies from a derivation.
///
/// Returns `(root_drv_path, relation)` pairs. `Opaque` (source) inputs are
/// skipped — only derivation build dependencies are returned. For each
/// `Built` input, the outermost output name (what we consume) is discarded;
/// intermediate output names form the [`OutputNameChain`].
pub fn input_drvs(drv: &Derivation) -> BTreeSet<(StorePath, OutputNameChain)> {
    drv.inputs
        .iter()
        .filter_map(|sdp| match sdp {
            SingleDerivedPath::Opaque(_) => None,
            SingleDerivedPath::Built { drv_path, .. } => Some(flatten_path(drv_path)),
        })
        .collect()
}
