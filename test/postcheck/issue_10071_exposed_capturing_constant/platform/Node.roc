import HostValue exposing [HostValue]

Node := [].{
    new_token : {} -> Box(U64)
    new_token = |_| Box.box(0)

    SignalExpr := [
        LocationSource(Box(U64), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
        UnusedSource(Box((HostValue -> Str))),
    ]
}
