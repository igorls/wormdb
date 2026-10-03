const core_predicate = @import("../core/predicate.zig");

pub const PredicateError = core_predicate.PredicateError;
pub const Literal = core_predicate.Literal;
pub const Operator = core_predicate.Operator;
pub const Clause = core_predicate.Clause;
pub const Predicate = core_predicate.Predicate;
pub const parse = core_predicate.parse;
