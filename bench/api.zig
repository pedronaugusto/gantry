// Borrow the same observations before and after opaque ownership.
const gantry = @import("gantry");
pub fn items(paths: *const gantry.Paths) []const []const u8 {
    return if (@hasDecl(gantry.Paths, "items")) paths.items() else paths.items;
}
pub fn edges(g: *const gantry.Graph) []const gantry.Edge {
    return if (@hasDecl(gantry.Graph, "edges")) g.edges() else g.edges;
}
pub fn references(g: *const gantry.Graph) []const gantry.Reference {
    return if (@hasDecl(gantry.Graph, "references")) g.references() else g.references;
}
pub fn dependencies(g: *const gantry.Graph) []const gantry.Dependency {
    return if (@hasDecl(gantry.Graph, "dependencies")) g.dependencies() else g.dependencies;
}
pub fn unread(g: *const gantry.Graph) []const []const u8 {
    return if (@hasDecl(gantry.Graph, "unread")) g.unread() else g.unread;
}
pub fn components(a: *const gantry.Analysis) []const []const []const u8 {
    return if (@hasDecl(gantry.Analysis, "components")) a.components() else a.components;
}
pub fn cycles(a: *const gantry.Analysis) []const gantry.Cycle {
    return if (@hasDecl(gantry.Analysis, "cycles")) a.cycles() else a.cycles;
}
