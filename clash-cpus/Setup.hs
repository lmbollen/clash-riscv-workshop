import Distribution.Simple
import VexRiscv.Setup (VexRiscvSource (VexRiscvBundled), addVexRiscvHooks)

main :: IO ()
main =
  defaultMainWithHooks
    ( addVexRiscvHooks
        simpleUserHooks
        "data"
        [ "Riscv32imc"
        ]
        VexRiscvBundled
    )
