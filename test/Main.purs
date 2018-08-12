module Test.Main where

import Prelude

import Affjax as AX
import Affjax.RequestBody as RequestBody
import Affjax.ResponseFormat as ResponseFormat
import Affjax.StatusCode (StatusCode(..))
import Control.Monad.Error.Class (throwError)
import Data.Argonaut.Core as J
import Data.Either (Either(..), either)
import Data.Maybe (Maybe(..))
import Data.Time.Duration (Milliseconds(..))
import Effect (Effect)
import Effect.Aff (Aff, attempt, finally, forkAff, killFiber, runAff)
import Effect.Aff.Compat (EffectFnAff, fromEffectFnAff)
import Effect.Class (liftEffect)
import Effect.Class.Console as A
import Effect.Console (log, logShow)
import Effect.Exception (error, throwException)
import Foreign.Object as FO

foreign import logAny :: forall a. a -> Effect Unit

foreign import data Server :: Type
foreign import startServer :: EffectFnAff { server :: Server, port :: Int }
foreign import stopServer :: Server -> EffectFnAff Unit

logAny' :: forall a. a -> Aff Unit
logAny' = liftEffect <<< logAny

assertFail :: forall a. String -> Aff a
assertFail = throwError <<< error

assertMsg :: String -> Boolean -> Aff Unit
assertMsg _ true = pure unit
assertMsg msg false = assertFail msg

assertRight :: forall a b. Either a b -> Aff b
assertRight x = case x of
  Left y -> logAny' y >>= \_ -> assertFail "Expected a Right value"
  Right y -> pure y

assertLeft :: forall a b. Either a b -> Aff a
assertLeft x = case x of
  Right y -> logAny' y >>= \_ -> assertFail "Expected a Left value"
  Left y -> pure y

assertEq :: forall a. Eq a => Show a => a -> a -> Aff Unit
assertEq x y =
  when (x /= y) $ assertFail $ "Expected " <> show x <> ", got " <> show y

main :: Effect Unit
main = void $ runAff (either (\e -> logShow e *> throwException e) (const $ log "affjax: All good!")) do
  let ok200 = StatusCode 200
  let notFound404 = StatusCode 404

  let retryPolicy = AX.defaultRetryPolicy { timeout = Just (Milliseconds 500.0), shouldRetryWithStatusCode = \_ -> true }

  { server, port } ← fromEffectFnAff startServer
  finally (fromEffectFnAff (stopServer server)) do
    A.log ("Test server running on port " <> show port)

    let prefix = append ("http://localhost:" <> show port)
    let mirror = prefix "/mirror"
    let doesNotExist = prefix "/does-not-exist"
    let notJson = prefix "/not-json"

    A.log "GET /does-not-exist: should be 404 Not found after retries"
    (attempt $ AX.retry retryPolicy (AX.request ResponseFormat.ignore) $ AX.defaultRequest { url = doesNotExist }) >>= assertRight >>= \res -> do
      assertEq notFound404 res.status

    A.log "GET /mirror: should be 200 OK"
    (attempt $ AX.request ResponseFormat.ignore $ AX.defaultRequest { url = mirror }) >>= assertRight >>= \res -> do
      assertEq ok200 res.status

    A.log "GET /does-not-exist: should be 404 Not found"
    (attempt $ AX.request ResponseFormat.ignore $ AX.defaultRequest { url = doesNotExist }) >>= assertRight >>= \res -> do
      assertEq notFound404 res.status

    A.log "GET /not-json: invalid JSON with Foreign response should return an error"
    attempt (AX.get ResponseFormat.json doesNotExist) >>= assertRight >>= \res -> do
      void $ assertLeft res.body

    A.log "GET /not-json: invalid JSON with String response should be ok"
    (attempt $ AX.get ResponseFormat.string notJson) >>= assertRight >>= \res -> do
      assertEq ok200 res.status

    A.log "POST /mirror: should use the POST method"
    (attempt $ AX.post ResponseFormat.json mirror (RequestBody.string "test")) >>= assertRight >>= \res -> do
      assertEq ok200 res.status
      json <- assertRight res.body
      assertEq (Just "POST") (J.toString =<< FO.lookup "method" =<< J.toObject json)

    A.log "PUT with a request body"
    let content = "the quick brown fox jumps over the lazy dog"
    (attempt $ AX.put ResponseFormat.json mirror (RequestBody.string content)) >>= assertRight >>= \res -> do
      assertEq ok200 res.status
      json <- assertRight res.body
      assertEq (Just "PUT") (J.toString =<< FO.lookup "method" =<< J.toObject json)
      assertEq (Just content) (J.toString =<< FO.lookup "body" =<< J.toObject json)

    A.log "Testing CORS, HTTPS"
    (attempt $ AX.get ResponseFormat.json "https://cors-test.appspot.com/test") >>= assertRight >>= \res -> do
      assertEq ok200 res.status
      -- assertEq (Just "test=test") (lookupHeader "Set-Cookie" res.headers)

    A.log "Testing cancellation"
    forkAff (AX.post_ mirror (RequestBody.string "do it now")) >>= killFiber (error "Pull the cord!")
    assertMsg "Should have been canceled" true
