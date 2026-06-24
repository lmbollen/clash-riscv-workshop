import Prelude

import Test.Tasty

import qualified Tests.Workshop.Project

main :: IO ()
main = defaultMain $ testGroup "."
  [ Tests.Workshop.Project.accumTests
  ]
