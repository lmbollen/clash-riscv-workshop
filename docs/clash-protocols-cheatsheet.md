# `clash-protocols` cheatsheet

A quick reference for the [`clash-protocols`](https://github.com/clash-lang/clash-protocols)
library: the protocols it ships and the combinators you use to wire, transform
and simulate them.

> **See also:** [circuit-notation-cheatsheet.md](circuit-notation-cheatsheet.md)
> for the `circuit … -<` arrow DSL. This sheet is about the *library*; that one
> is about the *syntax*.
>
> Memory-map and register machinery (`Protocols.MemoryMap.*`, `deviceWbI`,
> `registerWbDfI`, …) live in the separate **`clash-protocols-memmap`** package
> and are documented in
> [clash-protocols-memmap-cheatsheet.md](clash-protocols-memmap-cheatsheet.md).

---

## 1. What is `clash-protocols`?

`clash-protocols` is a library for building hardware out of **composable
components that speak a protocol**. Each component is a `Circuit a b`: its left
side speaks protocol `a`, its right side speaks protocol `b`. A *protocol* fixes
what flows in each direction — data going *forward* (`Fwd`) and a handshake
(ready/acknowledge) coming *backward* (`Bwd`):

```haskell
class Protocol a where
  type Fwd a   -- sender   -> receiver  (data)
  type Bwd a   -- receiver -> sender    (backpressure / acknowledge)

newtype Circuit a b = Circuit ((Fwd a, Bwd b) -> (Bwd a, Fwd b))
```

The payoff: when you connect circuits, the library **routes the backward wires
for you**, so you describe the forward data flow and get correct handshaking for
free. (The `Circuit`/`Protocol` types are covered in depth in the
[circuit-notation cheatsheet](circuit-notation-cheatsheet.md#1-the-two-core-types-protocol-and-circuit).)

The package gives you:

- **Ready-made protocols** — `Df`, `Wishbone`, `ReqResp`, `PacketStream`, … (§2).
- **Combinators** to connect and compose circuits (§3), transform and route
  dataflow (§4), and work with vectors of circuits (§5).
- **Idle sources/sinks** and an escape hatch to raw `Signal`s (§6).
- A **simulation & testing** framework (§7).
- The **circuit-notation plugin** (enable with `-fplugin Protocols.Plugin`).

Typical imports:

```haskell
import Protocols                                  -- Circuit, idC, (|>), (<|), applyC, …
import qualified Protocols.Df as Df               -- dataflow combinators
import qualified Protocols.Vec as Vec             -- vector-of-circuits reshapers
import qualified Protocols.ToConst as ToConst     -- constant channels
import Protocols.Idle                             -- idleSink / idleSource
import Protocols.Experimental.Wishbone            -- Wishbone bus  (Experimental)
import Protocols.Experimental.ReqResp             -- request/response (Experimental)
```

---

## 2. Protocols

A protocol is a (usually constructor-less) phantom type; its `Fwd`/`Bwd`
instances decide the actual wire types. These are the ones you meet most in this
workshop.

### `Df dom a` — dataflow with backpressure

The workhorse streaming protocol: the sender offers `Just a` (or `Nothing` when
it has nothing), and the receiver answers with an `Ack`.

```haskell
data Df (dom :: Domain) (a :: Type)
type Fwd (Df dom a) = Signal dom (Maybe a)   -- data, or Nothing = no data this cycle
type Bwd (Df dom a) = Signal dom Ack
newtype Ack = Ack Bool                        -- Ack True = receiver consumed the data
```

```haskell
-- combinational map over the payload
increment :: Circuit (Df dom Int) (Df dom Int)
increment = Df.map (+1)
```

```haskell
-- route matching elements to the first output, the rest to the second
(odds, evens) <- Df.partition even -< numbers
```

### `ReqResp dom req resp` — request / response (Experimental)

A memory-style channel: a request travels forward, its response comes back.

```haskell
data ReqResp (dom :: Domain) (req :: Type) (resp :: Type)
type Fwd (ReqResp dom req resp) = Signal dom (Maybe req)
type Bwd (ReqResp dom req resp) = Signal dom (Maybe resp)
```

```haskell
-- split an Either-request stream into read/write channels, then turn the
-- write side (which needs no response) into a plain Df stream:
(reads, writes0) <- ReqResp.partitionEithers -< reqresp
writes1          <- ReqResp.requests <| ReqResp.dropResponse 0 -< writes0
```

### `Wishbone dom mode aw dw` — classic bus (Experimental)

A full Wishbone master/subordinate bus. `mode` is `'Standard` or `'Pipelined`;
`aw` is the address width, `dw` the number of data bytes.

```haskell
data WishboneMode = Standard | Pipelined
data Wishbone (dom :: Domain) (mode :: WishboneMode) (aw :: Nat) (dw :: Nat)
type Fwd (Wishbone dom mode aw dw) = Signal dom (WishboneM2S aw dw)   -- master -> subordinate
type Bwd (Wishbone dom mode aw dw) = Signal dom (WishboneS2M dw)      -- subordinate -> master

data WishboneM2S aw dw = WishboneM2S      -- key fields
  { addr :: BitVector aw, writeData :: BitVector (dw * 8), busSelect :: BitVector dw
  , busCycle, strobe, writeEnable, lock :: Bool
  , cycleTypeIdentifier :: CycleTypeIdentifier, burstTypeExtension :: BurstTypeExtension }
data WishboneS2M dw = WishboneS2M
  { readData :: BitVector (dw * 8), acknowledge, err, stall, retry :: Bool }
```

```haskell
emptyWishboneM2S :: (KnownNat aw, KnownNat dw) => WishboneM2S aw dw   -- all flags off
emptyWishboneS2M :: KnownNat dw => WishboneS2M dw
hasTerminateFlag :: WishboneS2M dw -> Bool                            -- acknowledge || err || retry
```

```haskell
-- build a response by field update; read fields with record dot-syntax
errorResponse       = emptyWishboneS2M{err = True}
isActive m2s        = m2s.busCycle && m2s.strobe
```

### `ToConst a` — a constant carried forward

`Fwd = a`, `Bwd = ()`. Pushes a compile-time / static value down the forward
wire, with nothing coming back.

```haskell
data ToConst (a :: Type)
ToConst.to   :: a -> Circuit () (ToConst a)          -- expose a constant
ToConst.from :: Circuit () (ToConst a) -> a          -- read it back out
```

### `ToConstBwd a` — a constant carried backward

The mirror image: `Fwd = ()`, `Bwd = a`. Lets a circuit hand a value *back* out
of its input side.

```haskell
data ToConstBwd (a :: Type)
ToConst.toBwd   :: a -> Circuit (ToConstBwd a) ()
ToConst.fromBwd :: Circuit (ToConstBwd a) () -> a
```

```haskell
-- drive a Vec of ToConstBwd channels with a Vec of constants
… (Vec.vecCircuits $ fmap ToConst.toBwd prefixes) -< pfxs
```

This is how the workshop threads its **memory map** back out of a design, as
`ToConstBwd Mm` on a circuit's input side (the `Mm` payload itself belongs to
the `clash-protocols-memmap` cheatsheet).

### Other protocols in the package

Not covered here, but available — each is just another `Protocol` instance:

| Protocol | Meaning |
|---|---|
| `CSignal dom a` | a bare `Signal dom a` as a protocol (`Bwd = ()`); the bridge to raw signals — see §6 |
| `()`, `(a, b, …)` | unit and tuples — bundle several ports into one side |
| `Vec n a` | `n` copies of protocol `a` |
| `Reverse a` | swap the `Fwd`/`Bwd` of `a` |
| `BiDf dom a b` | bidirectional dataflow |
| `PacketStream dom n meta` | packetised byte streams |
| `Axi4Stream`, `Axi4` (full), `Avalon` (MM/Stream) | industry bus protocols |
| `Clock`/`Reset`/`Enable`/`DiffClock dom` | Clash primitives as protocols |

---

## 3. Connecting & composing circuits

```haskell
idC     :: Circuit a a                                    -- identity / pass-through
(|>)    :: Circuit a b -> Circuit b c -> Circuit a c      -- compose left-to-right
(<|)    :: Circuit b c -> Circuit a b -> Circuit a c      -- compose right-to-left
repeatC :: Circuit a b -> Circuit (Vec n a) (Vec n b)     -- n parallel copies
applyC  :: (Fwd a -> Fwd b) -> (Bwd b -> Bwd a) -> Circuit a b   -- lift raw fns to a Circuit
prod2C  :: Circuit a b -> Circuit c d -> Circuit (a, c) (b, d)   -- put two side by side (also prod3C/prod4C)

-- reinterpret / rewrap
coerceCircuit  :: (Fwd a ~ Fwd a', Bwd a ~ Bwd a', Fwd b ~ Fwd b', Bwd b ~ Bwd b')
               => Circuit a b -> Circuit a' b'
reverseCircuit :: Circuit a b -> Circuit (Reverse b) (Reverse a)
mapCircuit     :: (Fwd a' -> Fwd a) -> (Bwd a -> Bwd a')
               -> (Fwd b -> Fwd b') -> (Bwd b' -> Bwd b) -> Circuit a b -> Circuit a' b'

-- drop to / lift from the underlying signal function
toSignals   :: Circuit a b -> ((Fwd a, Bwd b) -> (Bwd a, Fwd b))
fromSignals :: ((Fwd a, Bwd b) -> (Bwd a, Fwd b)) -> Circuit a b
```

```haskell
-- (<|) reads right-to-left: run the interconnect, then unzip its Vec output
(pfxs, wbs) <- Vec.unzip <| singleMasterInterconnectC -< (mmDbus, dBus0)
```

---

## 4. Transforming & routing dataflow (`Df`)

Combinators from `Protocols.Df` (imported qualified as `Df`). Terse signatures,
grouped by purpose.

**Transform**
```haskell
Df.map       :: (a -> b)         -> Circuit (Df dom a) (Df dom b)
Df.mapMaybe  :: (a -> Maybe b)   -> Circuit (Df dom a) (Df dom b)
Df.catMaybes ::                     Circuit (Df dom (Maybe a)) (Df dom a)
Df.filter    :: (a -> Bool)      -> Circuit (Df dom a) (Df dom a)
Df.fst       ::                     Circuit (Df dom (a, b)) (Df dom a)   -- also Df.snd
Df.either    :: (a -> c) -> (b -> c) -> Circuit (Df dom (Either a b)) (Df dom c)
Df.zipWith   :: (a -> b -> c)    -> Circuit (Df dom a, Df dom b) (Df dom c)
Df.zip       ::                     Circuit (Df dom a, Df dom b) (Df dom (a, b))
```

**Route / split / merge**
```haskell
Df.partition        :: (a -> Bool) -> Circuit (Df dom a) (Df dom a, Df dom a)
Df.partitionEithers ::                Circuit (Df dom (Either a b)) (Df dom a, Df dom b)
Df.route            :: KnownNat n  => Circuit (Df dom (Index n, a)) (Vec n (Df dom a))
Df.select           :: KnownNat n  => Circuit (Vec n (Df dom a), Df dom (Index n)) (Df dom a)
Df.fanout           :: (KnownNat n, HiddenClockResetEnable dom, 1 <= n)
                                   => Circuit (Df dom a) (Vec n (Df dom a))
Df.fanin            :: (KnownNat n, 1 <= n) => (a -> a -> a) -> Circuit (Vec n (Df dom a)) (Df dom a)
Df.roundrobin       :: (KnownNat n, HiddenClockResetEnable dom, 1 <= n)
                                   => Circuit (Df dom a) (Vec n (Df dom a))
Df.bundleVec        :: (KnownNat n, 1 <= n) => Circuit (Vec n (Df dom a)) (Df dom (Vec n a))
```

**Sources / sinks**
```haskell
Df.pure    :: a -> Circuit () (Df dom a)                 -- constant source
Df.empty   ::      Circuit () (Df dom a)                 -- never produces
Df.const   :: HiddenReset dom => b -> Circuit (Df dom a) (Df dom b)
Df.consume :: HiddenReset dom =>      Circuit (Df dom a) ()   -- always ack, discard
Df.void    :: HiddenReset dom =>      Circuit (Df dom a) ()
```

**Buffer / sanity**
```haskell
Df.registerFwd :: (NFDataX a, HiddenClockResetEnable dom) => Circuit (Df dom a) (Df dom a)
Df.registerBwd :: (NFDataX a, HiddenClockResetEnable dom) => Circuit (Df dom a) (Df dom a)
Df.fifo :: (HiddenClockResetEnable dom, KnownNat depth, NFDataX a, 1 <= depth)
        => SNat depth -> Circuit (Df dom a) (Df dom a)
Df.forceResetSanity :: (KnownDomain dom, HiddenReset dom) => Circuit (Df dom a) (Df dom a)
```

Most combinators also have a `Signal`-parameterised `…S` variant (`Df.mapS`,
`Df.filterS`, `Df.zipWithS`, …), and there are stateful reshapers
`Df.compander` / `Df.compressor` / `Df.expander` for many-to-one / one-to-many
streams.

---

## 5. Vectors of circuits (`Protocols.Vec`)

Reshape `Vec`s of protocols (all `KnownNat`-constrained):

```haskell
Vec.vecCircuits :: Vec n (Circuit a b) -> Circuit (Vec n a) (Vec n b)   -- lift n circuits
Vec.unzip  :: Circuit (Vec n (a, b)) (Vec n a, Vec n b)                  -- also unzip3/4/5
Vec.zip    :: Circuit (Vec n a, Vec n b) (Vec n (a, b))                  -- also zip3/4/5
Vec.split  :: Circuit (Vec (n0 + n1) c) (Vec n0 c, Vec n1 c)             -- also split3
Vec.append :: Circuit (Vec n0 c, Vec n1 c) (Vec (n0 + n1) c)             -- also append3
Vec.concat   :: Circuit (Vec n0 (Vec n1 c)) (Vec (n0 * n1) c)
Vec.unconcat :: SNat m -> Circuit (Vec (n * m) c) (Vec n (Vec m c))
```

```haskell
(pfxs, wbs)                         <- Vec.unzip <| singleMasterInterconnectC -< (mmDbus, dBus0)
([(mmI, iMemBus), dMemBus], extBus) <- Vec.split -< wbs   -- list-pattern splits a Vec
```

---

## 6. Idle & escaping to raw signals

```haskell
idleSource :: IdleCircuit p => Circuit () p   -- a source that never produces data
idleSink   :: IdleCircuit p => Circuit p ()   -- a sink that holds its backward wire idle
```

```haskell
-- terminate a Vec of unused ports
idleSink <| (Vec.vecCircuits $ fmap ToConst.toBwd prefixes) -< pfxs
```

When you need the raw `Signal` a protocol carries, use **`CSignal`** as the
bridge (`Fwd (CSignal dom a) = Signal dom a`, `Bwd = ()`) and `applyC`:

```haskell
data CSignal dom a
applyC :: (Fwd a -> Fwd b) -> (Bwd b -> Bwd a) -> Circuit a b
```

For example, this workshop-local helper drops a `Df` down to `CSignal`s so its
payload can be `fmap`'d directly (see the `Fwd` pattern in the
[circuit-notation cheatsheet](circuit-notation-cheatsheet.md#7-fwd--crossing-between-protocols-and-plain-signals)):

```haskell
-- NOTE: defined in this repo, not in clash-protocols
unsafeFromDf :: Circuit (Df dom a, CSignal dom Ack) (CSignal dom (Maybe a))
unsafeFromDf = Circuit $ \((dfFwd, dfBwd), _) -> ((dfBwd, ()), dfFwd)
```

---

## 7. Simulation & testing

> In this checkout the simulation/testing machinery lives under
> **`Protocols.Experimental.*`** — the core `Protocols` module does *not*
> re-export `simulateC` / `sampleC` / `drive` / `sample`, and there is no
> top-level `Protocols.Hedgehog`.

### Driving a whole circuit — `Protocols.Experimental.Simulate`

```haskell
data SimulationConfig = SimulationConfig
  { resetCycles :: Int, timeoutAfter :: Int, ignoreReset :: Bool }   -- def = 100 / maxBound / False

simulateCS :: (Drivable a, Drivable b) => Circuit a b -> ExpectType a -> ExpectType b
simulateC  :: (Drivable a, Drivable b)
           => Circuit a b -> SimulationConfig -> SimulateFwdType a -> SimulateFwdType b
```

`Drivable`/`Simulate`/`Backpressure` are the classes that make a protocol
simulable; `ExpectType a` is its "plain Haskell" view (for `Df dom a` it is
`[Maybe a]`), and `driveC` / `sampleC` turn lists into a source / read a sink.

### Df stream I/O — `Protocols.Experimental.Df`

```haskell
drive    :: KnownDomain dom => SimulationConfig -> [Maybe a] -> Circuit () (Df dom a)
sample   :: KnownDomain dom => SimulationConfig -> Circuit () (Df dom b) -> [Maybe b]
stall    :: KnownDomain dom => SimulationConfig -> StallAck -> [Int] -> Circuit (Df dom a) (Df dom a)
simulate :: KnownDomain dom
         => SimulationConfig
         -> (Clock dom -> Reset dom -> Enable dom -> Circuit (Df dom a) (Df dom b))
         -> [Maybe a] -> [Maybe b]
```

```haskell
import qualified Protocols.Experimental.Df as Df
import Protocols.Experimental.Simulate (def)

-- feed four cycles through `increment`; Nothing = an idle cycle, order preserved
Df.simulate def (\_clk _rst _en -> Df.map (+1)) [Just 1, Just 2, Nothing, Just 3]
-- => [Just 2, Just 3, Nothing, Just 4]
```

### Property testing — `Protocols.Experimental.Hedgehog`

Check a circuit against a pure Haskell **model**:

```haskell
idWithModel ::
  (Test a, Test b) =>
  ExpectOptions -> Gen (ExpectType a) -> (ExpectType a -> ExpectType b) -> Circuit a b -> Property

propWithModel ::
  (Test a, Test b) =>
  ExpectOptions ->
  Gen (ExpectType a) ->                                  -- input generator
  (ExpectType a -> ExpectType b) ->                      -- pure model
  Circuit a b ->                                         -- implementation
  (ExpectType b -> ExpectType b -> PropertyT IO ()) ->   -- how to compare outputs
  Property
```

```haskell
-- 'increment' should match `fmap (fmap (+1))` on any generated Df input
prop_increment :: Property
prop_increment =
  idWithModel defExpectOptions genInputs (fmap (fmap (+1))) increment
```

(`…SingleDomain` variants take a `Clock -> Reset -> Enable -> …` function for a
single domain.)

---

## 8. Quick reference

| I want to…                                   | Use…                                        |
|----------------------------------------------|---------------------------------------------|
| Pass a value through unchanged               | `idC`                                       |
| Chain circuits A then B                      | `a \|> b`  (or `b <| a`)                    |
| Map a function over a stream                 | `Df.map f`                                  |
| Drop elements from a stream                  | `Df.filter p`                               |
| Split a stream two ways                      | `Df.partition p` / `Df.partitionEithers`    |
| Broadcast / merge N streams                  | `Df.fanout` / `Df.fanin`                    |
| Buffer a stream                              | `Df.registerFwd`, `Df.fifo (SNat @d)`       |
| Split / recombine a `Vec` of ports           | `Vec.split` / `Vec.append` / `Vec.unzip`    |
| Terminate an unused port                     | `idleSink` (or `idleSource`)                |
| Send a static value forward / backward       | `ToConst.to` / `ToConst.toBwd`              |
| Reach the raw `Signal`                       | `CSignal` + `applyC` (or `Fwd` in notation) |
| Run a circuit in simulation                  | `simulateCS` / `Df.simulate`                |
| Property-test against a model                | `idWithModel` / `propWithModel`             |

**Gotchas**

- Circuit notation needs `-fplugin Protocols.Plugin` (per-module `OPTIONS_GHC`
  or in the `.cabal` `ghc-options`); without it `circuit`/`-<` error at runtime.
- `Wishbone`, `ReqResp` and everything in §7 are under
  `Protocols.Experimental.*` — import from there, not from `Protocols`.
- Simulation helpers are **not** re-exported by `Protocols`; import
  `Protocols.Experimental.Simulate` / `.Df` / `.Hedgehog` directly.
- `Protocols.Df` has **no** `fromList` — build a source with `Df.drive` /
  `Df.simulate` instead.
- Don't confuse library circuits with this repo's own helpers: `wbStorage`,
  `singleMasterInterconnect`, `arbiter`, `fromBlockRamWithMask`,
  `VexBoneMm` and `unsafeFromDf` are defined *in this workshop*, on top of
  `clash-protocols` — not by the package itself.
</content>
