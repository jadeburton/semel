// EventSink.swift
// SemelServer
//
// Where the handler puts an event. One method, so that the in-process connection can be
// the sink directly and the socket server can be a fan-out over its subscribed sessions
// without the handler knowing which it is talking to.

import SemelProtocol

public protocol EventSink: AnyObject {
    func deliver(_ event: Event)
}
