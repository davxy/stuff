# JAM Protocol Conformance Testing

The fuzzer can function as a JAM protocol conformance testing tool,
enabling validation of third-party implementations (the "target") against
expected behaviors.

Through targeted testing, the fuzzer exercises the target implementation,
verifying its conformance with the protocol by comparing key elements
(state root, key-value storage, etc.) against locally computed results.

In this case, the testing approach is strictly **black-box**, with no knowledge
of or access to the internal structure of the system under test.

### Workflow

The conformance testing process follows these steps:

1. Select a **run seed** for deterministic and reproducible execution.  
2. Generate a block using the internal authoring engine (or also a precomputed
   trace for a different reference).
3. Optionally mutate the block before processing (e.g. fault injection).
4. Locally import the block.  
5. Forward the block to the target implementation endpoint for processing.  
6. Retrieve the **posterior state root** from the target and compare it with the
   locally computed one: If the roots match, move on to the next iteration (step 2).  
7. Attempt to read the target's full **key/value storage**.
8. Terminate the execution and produce an execution **report** containing:  
   - **Seed**: The used seed value for deterministic reproduction.  
   - **Inputs and Results**: Prior state, block, and the locally computed
     posterior state.
   - **Target Comparison**: If the target's posterior state is available,
     generate a diff against the expected posterior state.  

The resulting report can be used to construct a precise, specialized test
vector designed to immediately reproduce the discrepancy observed in the target
implementation.

### No Reference Implementation

As there will never be a definitive reference implementation, and the Graypaper
is the only authoritative specification, treating the local fuzzer engine as a
reference is inaccurate. A mismatch between the fuzzer expectation and the
target does not automatically imply a bug in the target.

In case of discrepancy, the resulting test vector must be examined and the
expected behavior verified against the Graypaper to resolve the inconsistency.

### Communication Protocol

The fuzzer communicates with target implementations using a synchronous
**request-response** protocol over Unix domain sockets.

#### Protocol Messages

```asn1
-- Block and Header as defined by the gray paper

TrieKey ::= OCTET STRING (SIZE(31))

Hash ::= OCTET STRING (SIZE(32))
HeaderHash ::= Hash
StateRootHash ::= Hash

Version ::= SEQUENCE {
    major INTEGER (0..255),
    minor INTEGER (0..255),
    patch INTEGER (0..255)
}

PeerInfo ::= SEQUENCE {
    name             UTF8String,
    version          Version,
    protocol-version Version
}

KeyValue ::= SEQUENCE {
    key     TrieKey,
    value   OCTET STRING
}

State ::= SEQUENCE OF KeyValue

ImportBlock ::= Block

SetState ::= SEQUENCE {
    header  Header,
    state   State
}

GetState ::= HeaderHash

StateRoot ::= StateRootHash

Message ::= CHOICE {
    peer-info    [0] PeerInfo,
    import-block [1] ImportBlock,
    set-state    [2] SetState,
    get-state    [3] GetState,
    state        [4] State,
    state-root   [5] StateRoot
}
```

**Note**: The `Header` included in the `SetState` message is eventually
used - via its hash - to reference the associated state. It is conceptually
similar to the genesis header: like the genesis header, its contents do not
fully determine the state. In other words, the state must be accepted and
stored exactly as provided, regardless of the header's content.

#### Messages Codec

All messages are encoded according to the **JAM codec** format. Prior to
transmission, each encoded message is prefixed with its length, represented as a
32-bit little-endian integer.

##### Message Encoding Examples

**PeerInfo**

```json
{
  "peer_info" {
    "name": "fuzzer",
    "version": {
      "major": 0,
      "minor": 1,
      "patch": 23
    }
    "protocol_version": {
      "major": 0,
      "minor": 6,
      "patch": 6
    }
  }
}
```

Encoded:
```
0x0e000000 0x000666757a7a6572000117000606
^          ^ encoded-message
len-prefix
```

**StateRoot**

```json
{
  "state_root": "0x4559342d3a32a8cbc3c46399a80753abff8bf785aa9d6f623e0de045ba6701fe"
}
```

Encoded:
```
0x21000000 0x054559342d3a32a8cbc3c46399a80753abff8bf785aa9d6f623e0de045ba6701fe
^          ^ encoded-message
len-prefix
```

#### Connection Setup

1. **Target Setup**: The target implementation binds to and listens on a named
   Unix socket (e.g., `/tmp/jam_target.sock`).
2. **Fuzzer Connection**: The fuzzer connects to the target's socket to
   establish the communication channel.
3. **Handshake**: The two peers exchange `PeerInfo` messages to identify
   themselves and negotiate protocol versions. The target waits to receive the
   fuzzer's `PeerInfo` message first.

#### Message Types and Expected Responses

| Request | Response | Purpose |
|----------------|-------------------|---------|
| `PeerInfo` | `PeerInfo` | Handshake and versioning exchange |
| `SetState` | `StateRoot` | Initialize or reset target state |
| `ImportBlock` | `StateRoot` | Process block and return resulting state root |
| `GetState` | `State` | Retrieve posterior state associated to given header hash |

#### Message Flow

The protocol follows a strict request-response pattern where:
- The fuzzer always initiates requests
- The target must respond to each request before the next request is sent
- Responses are mandatory and must match the expected message type for each request
- State roots are compared after each block import to detect discrepancies
- Full state retrieval via `GetState` is only performed when state root
  mismatches are detected
- Unexpected or malformed messages result in blunt session termination
- The fuzzer may implement timeouts for target responses
- The fuzzing session is terminated by the fuzzer closing the connection.
  No explicit termination message is sent.

**Typical Session Flow:**

```
             Fuzzer           Target
                |    PeerInfo    |
                | -------------> |
                |    PeerInfo    |
                | <------------- |
                |                |
                |    SetState    |
                | -------------> | > Initialize target with genesis state
                |    StateRoot   | < Return state root
 Compare root < | <------------- |
                |                |
                |   ImportBlock  |
                | -------------> | > Process block #1
                |    StateRoot   | < Return new state root
 Compare root < | <------------- |
                |     ....       |
                |   ImportBlock  |
                | -------------> | > Process block #n
                |    StateRoot   | < Return new state root
 Compare root < | <------------- |
                |                |
                | (on mismatch)  |
                |   GetState     | 
                | -------------> | > Request full state for comparison
                |     State      | < Return full state
                | <------------- |
```
