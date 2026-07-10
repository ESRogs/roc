HostValue := [HostValue(U64)].{
    CapabilityHandle := {
        clone : Box((HostValue -> HostValue)),
        drop : Box((HostValue -> {})),
        eq : Box((HostValue, HostValue -> Bool)),
    }

    store_with_capability! : Box(a), CapabilityHandle -> HostValue
    take_with_capability! : HostValue, CapabilityHandle -> Box(a)
}
