import Capability exposing [Capability]
import Node

Signal(a) := { expr : Box(Node.SignalExpr), cap : Capability(a) }.{
    from_expr : Node.SignalExpr, Capability(a) -> Signal(a)
    from_expr = |expr, cap| { expr: Box.box(expr), cap }
}
