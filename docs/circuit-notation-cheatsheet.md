# Circuit notation cheatsheet

A quick reference for `clash-protocols`' **circuit notation** — the little arrow
DSL you see in files like [`Workshop/Peripheral.hs`](../clash-riscv/src/Workshop/Peripheral.hs)
and [`Workshop/Cpu.hs`](../clash-riscv/src/Workshop/Cpu.hs).

Circuit notation lets you wire protocol-carrying components together as if you
were drawing boxes and arrows, and the GHC plugin takes care of threading the
*backward* (acknowledge / ready) wires for you — the part that is tedious and
error-prone to route by hand.

> **See also:** [clash-protocols-cheatsheet.md](clash-protocols-cheatsheet.md)
> for the library itself — the protocols (`Df`, `Wishbone`, `ReqResp`, …) and
> combinators you wire together with this notation — and
> [clash-protocols-memmap-cheatsheet.md](clash-protocols-memmap-cheatsheet.md)
> for describing memory-mapped peripherals.

---

## 1. The two core types: `Protocol` and `Circuit`

Everything in `clash-protocols` is built on two ideas from
[`Protocols.Plugin`](https://github.com/clash-lang/clash-protocols).

### `Protocol` — a type-level description of one side of a wire

A *protocol* is a phantom type that describes what flows in each direction. The
class has two associated type families:

```haskell
class Protocol a where
  type Fwd (a :: Type)   -- data flowing sender -> receiver ("forward")
  type Bwd (a :: Type)   -- data flowing receiver -> sender ("backward")
```

For example, `Df` (dataflow) sends `Maybe a` forward and an acknowledgement
back:

```haskell
instance Protocol (Df dom a) where
  type Fwd (Df dom a) = Signal dom (Maybe a)
  type Bwd (Df dom a) = Signal dom Ack
```

Protocols compose structurally, so you rarely write instances yourself:

| Protocol            | `Fwd`                     | `Bwd`                     |
|---------------------|---------------------------|---------------------------|
| `()`                | `()`                      | `()`                      |
| `(a, b)`            | `(Fwd a, Fwd b)`          | `(Bwd a, Bwd b)`          |
| `Vec n a`           | `Vec n (Fwd a)`           | `Vec n (Bwd a)`           |
| `CSignal dom a`     | `Signal dom a`            | `()`                      |
| `ToConstBwd a`      | `()`                      | `a`                       |
| `Df dom a`          | `Signal dom (Maybe a)`    | `Signal dom Ack`          |
| `Wishbone dom m aw dw` | `Signal dom (WishboneM2S …)` | `Signal dom (WishboneS2M …)` |

Tuples and `Vec` are themselves protocols, which is what lets you bundle many
ports into one circuit side.

### `Circuit` — a component with a left side and a right side

```haskell
newtype Circuit a b =
  Circuit ((Fwd a, Bwd b) -> (Bwd a, Fwd b))
```

`a` and `b` are *protocols*, not the raw signal types. A `Circuit a b` is a
component whose **left** side speaks protocol `a` and whose **right** side
speaks protocol `b`:

```
            Circuit a b
           +-----------+
    Fwd a  |           |  Fwd b
  +------->+           +-------->
           |           |
    Bwd a  |           |  Bwd b
  <--------+           +<-------+
           +-----------+
```

You *can* build a `Circuit` by hand from that function
(see [`singleMasterInterconnectC`](../clash-riscv/src/Wishbone.hs) which uses
`Circuit go`), but for wiring components together, circuit notation is far
nicer.

---

## 2. `circuit` — activate the plugin

Two things turn on the DSL:

1. Enable the plugin in the module (either form works):

   ```haskell
   {-# OPTIONS_GHC -fplugin Protocols.Plugin #-}
   -- or
   {-# OPTIONS -fplugin=Protocols.Plugin #-}
   ```

   (It can also be set once for the whole package under `ghc-options` in the
   `.cabal` file — see [`clash-riscv.cabal`](../clash-riscv/clash-riscv.cabal).)

2. Write your circuit as `circuit $ \input -> do …`.

The `circuit` function is a *marker*. On its own it just throws an error — its
whole purpose is to be spotted and rewritten by the plugin:

```haskell
circuit :: Any
circuit = error "'circuit' called: did you forget to enable \"Protocols.Plugin\"?"
```

If you ever see that runtime error, the `-fplugin` flag is missing.

A minimal skeleton:

```haskell
myCircuit :: Circuit a b
myCircuit = circuit $ \input -> do
  ...
  someRhs -< output
```

Everything between `circuit $ \… -> do` and the final statement is the DSL.

---

## 3. Lambda arguments = the circuit's inputs

The lambda binds the **left side** (`a`) of the resulting `Circuit a b`. The
names you introduce become the input ports you can drive downstream.

```haskell
processingElement … = circuit $ \(mm, jtagIn) -> do
  ...
```

Here the circuit's left protocol is `(ToConstBwd Mm.Mm, Jtag dom)`, and the
lambda destructures it into the two named ports `mm` and `jtagIn`. A
single-input circuit just uses one name: `\input -> …`.

---

## 4. `-<` — the arrow that connects things

Inside the `do` block, `-<` feeds a value into the **left** side of a component
and binds what comes out of its **right** side:

```haskell
result <- component -< input
```

Read it as: *drive `component` with `input`, call its output `result`.*

```haskell
(iBus0, (mmDbus, dBus0)) <-
  rvCircuit dumpVcd (pure low) (pure low) (pure low) -< (mm, jtagIn)
```

The component on the left of `-<` is any `Circuit x y` (fully applied to its
non-protocol arguments). The thing on the right of `-<` must match its left
protocol `x`; the bound result has its right protocol `y`.

A few things worth knowing:

- **Bindings can be used before they are defined.** The plugin builds one big
  recursive network, so forward references are fine — this is how feedback loops
  are expressed:

  ```haskell
  iBus1 <- removeMsb -< iBus0
  ...
  -- iBus2 is used here, defined on the next line
  ... -< (mmI, iBus2)
  iBus2 <- arbiter -< [iMemBus, iBus1]
  ```

- **`let` introduces ordinary Haskell values**, not circuits. Use it for plain
  signals you want to reference (often together with `Fwd`, see §7):

  ```haskell
  let readAvailable = fmap (Ack . isJust) byteIn1
  ```

- **Composition operators still work** on the left of `-<`. `<|` and `|>` chain
  circuits, and `idC` is the identity/pass-through circuit:

  ```haskell
  (pfxs, wbs) <- Vec.unzip <| singleMasterInterconnectC -< (mmDbus, dBus0)
  ```

---

## 5. Driving the right-hand side (the output)

The **last statement** of the `do` block wires up the circuit's **right** side
(`b`) — its output. Whatever you drive there becomes the output of the whole
`circuit`.

The most common ending is `idC`, which just forwards a named value out as the
circuit's result:

```haskell
processingElement … = circuit $ \(mm, jtagIn) -> do
  ...
  idC -< extBusses            -- 'extBusses' becomes the circuit's right-side output
```

You can equally end on any other circuit — the final `-<` just needs its
*right* protocol to match the `b` in your `Circuit a b` signature:

```haskell
serialBytes = circuit $ \(byteIn0, wb) -> do
  ...
  applyC (fmap busActivityWrite) id -< busWrite   -- this circuit's RHS is the output
```

So there are two "driving" directions to keep straight:

- `c -< x` drives the **left** side of the sub-component `c` with `x`.
- The **final** statement drives the **right** side of the *whole* circuit.

---

## 6. Pattern matching: tuples and `Vec` (list syntax)

Because tuples and `Vec` are protocols, you can destructure them on **either**
side of `-<`, and on the lambda argument.

### Tuples

```haskell
-- destructure the lambda input
circuit $ \(mm, jtagIn) -> do

-- destructure a binding
(iBus0, (mmDbus, dBus0)) <- rvCircuit … -< (mm, jtagIn)
(busWrite, busRead)      <- Df.partition isBusWrite -< busActivity

-- build a tuple to drive an input
… -< (mm, jtagIn)
```

Nested tuples work too, as in `(iBus0, (mmDbus, dBus0))` above.

### Vectors — use list syntax

A `Vec n p` of protocols is pattern-matched and constructed with **`[ … ]`
list syntax** (the plugin maps it onto `Vec`'s cons):

```haskell
-- bind each element of a Vec-of-protocols output to a name
[wb0] <- deviceWbI deviceCfg -< wb

-- match a fixed-shape Vec, keeping the tail as another Vec ('extBusses')
([(mmI, iMemBus), dMemBus], extBusses) <- Vec.split -< wbs

-- build a Vec to drive an input
iBus2 <- arbiter -< [iMemBus, iBus1]
```

Note in the second example how list-pattern and tuple-pattern nest freely:
`[(mmI, iMemBus), dMemBus]` is a 2-element `Vec` whose elements are themselves
tuple protocols.

---

## 7. `Fwd` — crossing between protocols and plain signals

Sometimes you need to step outside the protocol world and work with the raw
`Signal` that a protocol carries in its forward direction — for example to
combine it with `fmap`, or to break a `Df`'s automatic backpressure on purpose.
The `Fwd` marker does this **in both directions** inside circuit notation.

Recall (§1) that `Fwd p` is the *forward* signal type of protocol `p`, e.g.
`Fwd (CSignal dom a) = Signal dom a`.

### Deconstruct: `Protocol p`  →  `Fwd p`  (on the left of `<-`)

Put `Fwd` in the **binding pattern** to unwrap a protocol port into its plain
forward signal:

```haskell
Fwd byteIn1 <- unsafeFromDf -< (byteIn0, Fwd busReadAck)
--  ^^^^^^^ byteIn1 :: Signal dom (Maybe a), because unsafeFromDf's RHS is a
--          CSignal dom (Maybe a), and Fwd (CSignal dom (Maybe a)) = Signal dom (Maybe a)
```

Now `byteIn1` is an ordinary `Signal` you can `fmap` over:

```haskell
let readAvailable = fmap (Ack . isJust) byteIn1
```

### Construct: `Fwd p`  →  `Protocol p`  (on the right of `-<`)

Put `Fwd` around a plain signal to lift it **into** a protocol port when driving
an input:

```haskell
Fwd busReadData <- unsafeFromDf -< (busRead, Fwd readAvailable)
--                                            ^^^^^^^^^^^^^^^^^
-- readAvailable :: Signal dom Ack  is wrapped into a CSignal dom Ack port
```

And you can feed a `Fwd`-deconstructed signal straight back into another
component's input, still wrapped:

```haskell
(_reg, busActivity) <- registerWbDfI registerCfg 0 -< (wb0, Fwd byteIn1)
```

So the rule of thumb:

| Where you write it        | What `Fwd` does                                   |
|---------------------------|---------------------------------------------------|
| `Fwd x <- c -< …`         | **deconstruct**: unwrap the output port into a plain `Signal x` |
| `c -< (…, Fwd s)`         | **construct**: wrap plain signal `s` into a protocol port       |

This is exactly the pair used to bridge into and out of `CSignal` around the
`unsafeFromDf` helper in [`Workshop/Peripheral.hs`](../clash-riscv/src/Workshop/Peripheral.hs).

---

## 8. A complete worked example

Every feature above appears in `serialBytes` — a good template to read whole
(from [`Workshop/Peripheral.hs`](../clash-riscv/src/Workshop/Peripheral.hs)):

```haskell
serialBytes ::
  ( … ) =>
  Circuit
    (Df dom (BitVector 8), (ToConstBwd Mm, Wishbone dom 'Standard aw width))
    (Df dom (BitVector 8))
serialBytes = circuit $ \(byteIn0, wb) -> do        -- §3 lambda binds two inputs
  [wb0] <- deviceWbI deviceCfg -< wb                -- §6 Vec/list pattern
  Fwd byteIn1 <- unsafeFromDf -< (byteIn0, Fwd busReadAck)   -- §7 deconstruct + construct
  (_reg, busActivity) <- registerWbDfI registerCfg 0 -< (wb0, Fwd byteIn1)  -- §6 tuple, §7 construct
  let readAvailable = fmap (Ack . isJust) byteIn1   -- §4 plain let over a Fwd signal
  Fwd busReadData <- unsafeFromDf -< (busRead, Fwd readAvailable)
  let busReadAck = fmap (Ack . isJust) busReadData  -- used above before definition (§4)
  (busWrite, busRead) <- Df.partition isBusWrite -< busActivity  -- §6 tuple, §4 forward ref
  applyC (fmap busActivityWrite) id -< busWrite     -- §5 final statement = output
 where
  ...
```

---

## Quick reference

| I want to…                                  | Write…                                  |
|---------------------------------------------|-----------------------------------------|
| Turn on the DSL                             | `{-# OPTIONS_GHC -fplugin Protocols.Plugin #-}` |
| Start a circuit                             | `circuit $ \input -> do …`              |
| Name the circuit's inputs                   | lambda pattern: `\(a, b) -> …`          |
| Drive a sub-component and bind its output   | `out <- comp -< in`                     |
| Produce the circuit's output                | final statement, e.g. `idC -< out`      |
| Destructure a tuple port                    | `(x, y) <- comp -< in`                  |
| Destructure a `Vec` of ports                | `[x, y] <- comp -< in`                  |
| Split a `Vec` head/tail                     | `([x, y], rest) <- Vec.split -< in`     |
| Unwrap a port to a plain `Signal`           | `Fwd s <- comp -< in`                   |
| Wrap a plain `Signal` into a port           | `comp -< (…, Fwd s)`                     |
| Reference a plain signal                    | `let s = fmap f x`                      |

**Gotchas**

- The `'circuit' called: did you forget to enable "Protocols.Plugin"?` error at
  runtime means the plugin flag is missing.
- Names are one big recursive `let` — order does not matter, but every name must
  be produced exactly once and used somewhere (unused ports become type errors).
- The thing left of `-<` is a `Circuit`; the thing right of `-<` must match its
  **left** protocol. The name you bind has its **right** protocol.
</content>
</invoke>
