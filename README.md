# WiTSnet

Wired and Wireless Transport in Synchronized networks.

```text
                 WiTSnet Network

  +----------------------+           +----------------------+
  |      Controller      |           |        Device        |
  +----------------------+           +----------------------+
  | initiates exchanges  |           | responds and         |
  | and sends requests   |           | provides data        |
  +----------------------+           +----------------------+
              |                                  ^
              | requests / cyclic control        |
              +--------------------------------->|
              |                                  |
              | replies / process data           |
              |<---------------------------------+

                   transport: EtherType B081
                              UDP port 45185
                              TCP port 45185
```

- `Controller`: initiates configuration, cyclic control exchanges, and request/command traffic.
- `Device`: receives controller requests, provides process/service data, and returns replies.
