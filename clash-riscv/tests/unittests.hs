import Prelude

import Test.Tasty

import qualified Tests.Workshop.Peripheral.Encoder
import qualified Tests.Workshop.Project

main :: IO ()
main = defaultMain $ testGroup "."
  [ Tests.Workshop.Project.accumTests
  , Tests.Workshop.Peripheral.Encoder.peripheralTests
  ]
