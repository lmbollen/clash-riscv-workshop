# `clash-protocols-memmap` cheatsheet

A quick reference for **`clash-protocols-memmap`**: how you describe
memory-mapped peripherals in a Clash design so the build can emit a
`memory_maps/*.json` — the single source of truth that ties hardware register
addresses to the firmware.

> **See also:** [clash-protocols-cheatsheet.md](clash-protocols-cheatsheet.md)
> (the `Circuit`/`Df`/`Wishbone` building blocks) and
> [circuit-notation-cheatsheet.md](circuit-notation-cheatsheet.md) (the
> `circuit … -<` DSL).
>
> What the generated JSON turns into — the Rust PAC modules, HAL patterns, and
> the macro for reusing one HAL across monomorphised device instances — is
> covered in its own separate cheatsheet.

---

## 1. What is `clash-protocols-memmap`?

You build peripherals on a Wishbone bus (see the
[clash-protocols cheatsheet](clash-protocols-cheatsheet.md#2-protocols)). This
package lets each peripheral **declare its registers and their layout** as part
of that circuit. Those declarations are collected into a **memory map** that:

- travels **backward** out of the circuit on a `ToConstBwd Mm` port (so a device
  *emits* its map alongside the forward bus it *accepts*),
- **composes** automatically — an interconnect merges its children's maps into
  one, placing each under its base address,
- is, at build time, **written to JSON** describing every device, register,
  address and access mode. That JSON drives the firmware's typed register
  accessors and linker script.

So the workflow is: *annotate devices → get one aggregate memory map → emit
JSON*. This sheet covers all three, plus what a register value's type needs
(`BitPackC`).

Typical imports:

```haskell
import Protocols.MemoryMap                              -- Mm, MemoryMap, withTag, getMMAny, …
import Protocols.MemoryMap.Registers.WishboneStandard   -- deviceWbI, registerWbDfI, addressableBytesWb, …
import Clash.Class.BitPackC (ByteOrder (..), Bytes)     -- register-value layout (clash-bitpackc)
import qualified Protocols.MemoryMap.Json as Json       -- memoryMapJson, encode (JSON emission)
```

---

## 2. Building a peripheral: devices & registers

A memory-mapped peripheral is: **one device**, holding **one or more
registers**, sitting behind a Wishbone port that also carries the map
(`(ToConstBwd Mm, Wishbone …)`).

### Declare a device

```haskell
data DeviceConfig = DeviceConfig { name :: String, trace :: Bool, registered :: Bool }
deviceConfig :: String -> DeviceConfig            -- trace = False, registered = True

deviceWbI ::
  (KnownNat n, KnownNat wordSize, KnownNat aw, HiddenClock dom, HiddenReset dom) =>
  DeviceConfig ->
  Circuit (ToConstBwd Mm, Wishbone dom 'Standard aw wordSize)
          (Vec n (RegisterWb dom aw wordSize))
```

`deviceWbI` consumes the `(Mm, Wishbone)` port and hands back a **`Vec n` of
register slots** — bind them with a list pattern, one element per register:

```haskell
[statusSlot, dataSlot] <- deviceWbI (deviceConfig "MyDevice") -< wbMm
```

`registered = True` (the default) inserts a pipeline register on the bus↔register
path; set `{registered = False}` for a combinational device. Each slot is a
`RegisterWb dom aw wordSize` bundle — treat it as opaque and feed it straight
into a `registerWb*` builder below.

### Define registers

```haskell
registerConfig :: String -> String -> RegisterConfig   -- name -> description
-- RegisterConfig also has: tags = [], access = ReadWrite, busRead = PreferRegister

-- value output + a stream of bus hits (needs BitPackC a + ?byteOrder — see §5)
registerWbI ::
  (HiddenClock dom, HiddenReset dom, RegisterWbConstraints a dom wordSize aw) =>
  RegisterConfig -> a ->                              -- config + reset value
  Circuit (RegisterWb dom aw wordSize, CSignal dom (Maybe a))
          (CSignal dom a, CSignal dom (Maybe (BusActivity a)))

registerWbDfI ::                                       -- same, but bus hits as a Df stream
  (HiddenClock dom, HiddenReset dom, RegisterWbConstraints a dom wordSize aw) =>
  RegisterConfig -> a ->
  Circuit (RegisterWb dom aw wordSize, CSignal dom (Maybe a))
          (CSignal dom a, Df dom (BusActivity a))
```

The family (pick by output shape / clocking):

| Variant | Output side | Notes |
|---|---|---|
| `registerWb` / `registerWbI` | `(CSignal a, CSignal (Maybe (BusActivity a)))` | value + activity as a signal |
| `registerWbDf` / `registerWbDfI` | `(CSignal a, Df (BusActivity a))` | activity as a `Df` stream |
| `registerWb_` / `registerWbI_` | `()` | drop the outputs |
| `registerWbVec…` | maps a `Vec n a` register | |
| `registerWithOffsetWb…` | you supply the offset | uses `RegisterWithOffsetWb` |

Trailing **`I`** = hidden clock/reset (the plain names take `Clock`/`Reset`
explicitly).

### React to bus traffic — `BusActivity`

```haskell
data BusActivity a = BusRead a | BusWrite a
busActivityWrite :: Maybe (BusActivity a) -> Maybe a   -- keep only writes
busActivityRead  :: Maybe (BusActivity a) -> Maybe a   -- keep only reads
```

A register reports every access as a `BusActivity`. This peripheral pulls the
written bytes off the `Df` activity stream (from
[`Workshop/Peripheral.hs`](../clash-riscv/src/Workshop/Peripheral.hs)):

```haskell
serialBytes = circuit $ \(byteIn0, wb) -> do
  [wb0] <- deviceWbI (deviceConfig "SerialBytes") -< wb
  ...
  (_reg, busActivity) <- registerWbDfI (registerConfig "byte" "Receives or sends a single byte") 0
                            -< (wb0, Fwd byteIn1)
  -- Df.partition sends matches to the *first* output
  (busWrite, busRead) <- Df.partition isBusWrite -< busActivity
  applyC (fmap busActivityWrite) id -< busWrite       -- extract the written byte
```

### A whole memory range as one device — `addressableBytesWb`

For RAM-like devices, expose a block of `nWords` addressable words instead of
named registers. It turns the register slot into a `ReqResp` stream of
reads / masked writes:

```haskell
addressableBytesWb ::
  (KnownDomain dom, KnownNat nWords, KnownNat wordSize, KnownNat aw, 1 <= nWords, 1 <= wordSize) =>
  RegisterConfig ->
  Circuit (RegisterWb dom aw wordSize)
          ( ReqResp dom
              (Either (Index nWords)                                   -- read  addr
                      (Index nWords, BitVector wordSize, Bytes wordSize)) -- write addr+mask+data
              (Bytes wordSize) )
```

Used by the workshop's `wbStorage` (workshop-local, in
[`Workshop/Memory.hs`](../clash-riscv/src/Workshop/Memory.hs)):

```haskell
wbStorage memoryName SNat initContent = circuit $ \wbMm -> do
  [wb0]   <- deviceWbI (deviceConfig memoryName){registered = False} -< wbMm
  reqresp <- addressableBytesWb @depth (registerConfig "data" "Word-addressable storage") -< wb0
  (reads, writes0) <- ReqResp.partitionEithers -< reqresp
  writes1          <- ReqResp.requests <| ReqResp.dropResponse 0 -< writes0
  _vecUnit <- ram -< (reads, writes1)
  idC -< ()
```

---

## 3. Annotating the map: names, tags, addresses

Wrap a map-producing circuit to attach metadata. All have the shape
`… -> Circuit (ToConstBwd Mm, a) b -> Circuit (ToConstBwd Mm, a) b`:

```haskell
withName      :: HasCallStack => String   -> Circuit (ToConstBwd Mm, a) b -> Circuit (ToConstBwd Mm, a) b
withTag       :: HasCallStack => String   -> …   -- tag a map node        (withTags for a list)
withDeviceTag :: HasCallStack => String   -> …   -- tag the single device (withDeviceTags for a list)
withAbsAddr   :: HasCallStack => Address   -> …   -- assert an absolute address
```

The `"no-generate"` tag tells the code generator to skip a device (e.g. the
CPU-internal memories), from [`Workshop/Cpu.hs`](../clash-riscv/src/Workshop/Cpu.hs):

```haskell
Mm.withTag "no-generate"
  $ Mm.withDeviceTag "no-generate"
  $ wbStorage "DataMemory" depthD initD
  -< dMemBus
```

Also handy: `withMemoryMap` / `withPrefix` attach a map to a plain circuit,
`unMemmap` strips the `ToConstBwd Mm` port back off, and `ignoreMM` / `todoMM`
are placeholders for a not-yet-mapped design. (`withDeviceTag` errors unless the
wrapped circuit produces exactly one device.)

---

## 4. Composing & exposing the map

The recurring port shape is a bus paired with its backward-flowing map. The
workshop aliases it (in [`SharedTypes.hs`](../clash-riscv/src/SharedTypes.hs)):

```haskell
type VexBoneMm dom addressWidth = (ToConstBwd Mm, Wishbone dom 'Standard addressWidth 4)
```

An **interconnect** takes several such child ports and merges their maps into one
aggregate map, each child placed under its base address — so composing devices
composes their maps for free. (The workshop's `singleMasterInterconnectC` in
[`Wishbone.hs`](../clash-riscv/src/Wishbone.hs) is a workshop-local example of
this; you normally just wire devices through it.)

To pull the finished map out of a complete design:

```haskell
getMMAny :: (NFDataX (Fwd a), NFDataX (Bwd b)) => Circuit (ToConstBwd Mm, a) b -> MemoryMap
```

---

## 5. Register values: `BitPackC` & byte order

A register holds a value of some type `a`. To place that value on the bus, the
library needs to know its **byte layout**, which is what `BitPackC` provides
(from the `clash-bitpackc` package):

- **`BitPackC a`** fixes how `a` is laid out as bytes across consecutive bus
  addresses, following the **C ABI** — so a `repr(C)` struct in the firmware
  sees exactly the same bytes. You get it for free by deriving `Generic`.
- **`ByteOrder`** (`LittleEndian` / `BigEndian`) picks the endianness, supplied
  through the `?byteOrder :: ByteOrder` implicit parameter that every register /
  peripheral carries. **This SoC is little-endian** (the VexRiscv core;
  [`Cpu.hs`](../clash-riscv/src/Workshop/Cpu.hs) rejects `BigEndian` at compile
  time). The top entity binds it once: `let ?byteOrder = LittleEndian`.
- **`Bytes n = BitVector (n * 8)`** is the n-byte word type used for register /
  memory content.
- **`deriveTypeDescription`** (Template Haskell, from
  `Protocols.MemoryMap.TypeDescription`) records the type's *shape* — its
  constructors and fields — so the code generator can emit a matching firmware
  type. This is the `WithTypeDescription` half of a register's constraints.

So a custom register type is usually just:

```haskell
data Status = Status { ready :: Bool, count :: Unsigned 8 }
  deriving (Generic, NFDataX, BitPackC)

deriveTypeDescription ''Status     -- $(…) splice: describe Status for the code generator
```

That satisfies `RegisterWbConstraints` (`BitPackC a`, `WithTypeDescription a`,
`NFDataX a`, and `?byteOrder`), so `Status` can be used as a `registerWbI` value.

---

## 6. What the memory map contains

The value you get from `getMMAny` (and register in §7). You rarely build these by
hand, but this is what the JSON is made of:

```haskell
type Mm = SimOnly MemoryMap                 -- the ToConstBwd payload; SimOnly = simulation-only metadata

data MemoryMap = MemoryMap
  { deviceDefs :: Map DeviceName DeviceDefinition   -- every device, by name
  , tree       :: MemoryMapTree }                   -- how they're arranged in the address space

data DeviceDefinition = DeviceDefinition
  { deviceName :: Name, registers :: [NamedLoc Register], definitionLoc :: SrcLoc, tags :: [String] }

data Register = Register
  { access :: Access, address :: Address, fieldType :: RegisterType   -- type / size in bytes
  , reset :: Maybe Natural, tags :: [String] }

data Access = ReadOnly | WriteOnly | ReadWrite
data Name   = Name { name :: String, description :: String }          -- identifier + doc string
```

`access` comes from the register's `RegisterConfig`, `address` is assigned by the
enclosing interconnects, and `fieldType` carries the `BitPackC`/type-description
info from §5.

---

## 7. Writing the map to JSON

The map is emitted to `memory_maps/<name>.json` **at compile time**. In this
workshop that is done by the provided `Workshop.MemoryMaps` splice — you just add
your design's map to its list (README step 2):

```haskell
-- Workshop/MemoryMaps.hs — register each SoC's memory map here
let memoryMaps = [("Soc", getMMAny soc)] :: [(String, MemoryMap)]
```

Rebuild the Clash side and `memory_maps/Soc.json` appears. If the map has
problems (overlapping or oversized regions) the **build fails** with a located
error message instead of writing JSON.

Under the hood the provided splice hands your `MemoryMap` to the library's
emitters and reports any errors (you don't call these yourself):

```haskell
-- provided glue, condensed from Workshop/MemoryMaps.hs
if not (null errors)
  then mapM_ (reportError . getErrorMessage) errors        -- fail the build
  else BS.writeFile jsonPath                                -- memory_maps/<name>.json
         (Json.encode (Json.memoryMapJson Json.LocationSeparate mm.deviceDefs absTree))
```

That JSON is the hand-off point to the code generator — which turns it into the
Rust PAC and linker script (see
[code-generator-cheatsheet.md](code-generator-cheatsheet.md)).

---

## 8. Quick reference

| I want to…                                | Use…                                                    |
|-------------------------------------------|---------------------------------------------------------|
| Declare a peripheral                       | `deviceWbI (deviceConfig "Name")` → `[slot0, …]`        |
| Add a register                             | `registerWbI` / `registerWbDfI cfg resetVal -< (slot, …)` |
| Expose a RAM-like address range            | `addressableBytesWb cfg`                                |
| Name/describe a register                   | `registerConfig "name" "description"`                   |
| Make a register read-only / write-only     | `(registerConfig …){access = ReadOnly}`                 |
| React only to writes / reads               | `busActivityWrite` / `busActivityRead`                  |
| Skip code generation for a device          | `withTag "no-generate"` + `withDeviceTag "no-generate"` |
| Pin a device to an absolute address        | `withAbsAddr 0x…`                                       |
| Use a struct as a register value           | `deriving (Generic, NFDataX, BitPackC)` + `deriveTypeDescription` |
| Pull the map out of a design               | `getMMAny topCircuit`                                    |
| Emit the JSON                              | register `("Name", map)` in `Workshop.MemoryMaps`, rebuild |

**Gotchas**

- A register value type needs both `BitPackC a` and `?byteOrder :: ByteOrder`
  in scope; this SoC only supports `LittleEndian`.
- `withDeviceTag` requires the wrapped circuit to contain **exactly one** device.
- Trailing `I` = hidden clock/reset; the plain builders (`registerWb`,
  `deviceWb`) take `Clock`/`Reset` explicitly.
- The device's map flows **backward** (`ToConstBwd Mm`) — it's an output riding
  the input port, not something you feed in.
- Library vs workshop-local: `deviceWbI`, `registerWbDfI`, `addressableBytesWb`,
  `withTag`, `getMMAny` are from `clash-protocols-memmap`; `wbStorage`,
  `singleMasterInterconnectC`, `VexBoneMm` and the `Workshop.MemoryMaps` splice
  are defined **in this workshop**.
- The JSON is written **at compile time** by the `Workshop.MemoryMaps` TH splice
  — rebuild the Clash side before the firmware so the map stays current.
</content>
