module Yoga.Om.Rom
  ( omToEvent
  , eventToOm
  , streamOms
  , raceEvents
  , filterMapOm
  , foldOms
  , EventOmCanceller
  , withEventStream
  ) where

import Prelude

import Control.Alt ((<|>))
import Control.Plus (empty)
import Data.Either (either)
import Data.Foldable (foldr)
import Data.Maybe (Maybe(..))
import Data.Variant (class VariantMatchCases)
import Effect (Effect)
import Effect.Aff (Aff, launchAff_)
import Effect.Class (liftEffect)
import Control.Monad.ST.Class (liftST)
import Effect.Exception (Error)
import Effect.Ref as Ref
import Effect.Unsafe (unsafePerformEffect)
import FRP.Event (Event, makeEventE, subscribe)
import Prim.Row (class Union)
import Prim.RowList (class RowToList)
import Yoga.Om (Om)
import Yoga.Om as Om

-- | A canceller for event-based Om operations
type EventOmCanceller = Effect Unit

-- | Convert an Om computation to a Hyrule Event
-- | The event fires once when the Om completes successfully
-- | Errors are handled by the provided error handler in the context
omToEvent
  :: forall ctx r rl err_ err a
   . RowToList (exception :: Error -> Aff a | r) rl
  => VariantMatchCases rl err_ (Aff a)
  => Union err_ () (exception :: Error | err)
  => ctx
  -> { exception :: Error -> Aff a | r }
  -> Om ctx err a
  -> Event a
omToEvent ctx handlers om = unsafePerformEffect do
  { event } <- makeEventE \push -> do
    launchAff_ do
      result <- Om.runOm ctx handlers om
      liftEffect $ push result
    pure $ pure unit
  pure event

-- | Convert a Hyrule Event stream to an Om computation
-- | Takes the first value emitted by the event
eventToOm
  :: forall ctx err a
   . Event a
  -> Om ctx err a
eventToOm event = Om.fromAff do
  resultRef <- liftEffect $ Ref.new Nothing
  canceller <- liftEffect $ liftST $ subscribe event \value -> do
    Ref.write (Just value) resultRef
  
  -- Wait for the first value
  let
    checkValue = do
      maybeValue <- liftEffect $ Ref.read resultRef
      case maybeValue of
        Just value -> do
          liftEffect $ liftST canceller
          pure value
        Nothing -> checkValue
  checkValue

-- | Stream multiple Om computations as events
-- | Creates an event that fires for each Om that completes
streamOms
  :: forall ctx r rl err_ err a
   . RowToList (exception :: Error -> Aff a | r) rl
  => VariantMatchCases rl err_ (Aff a)
  => Union err_ () (exception :: Error | err)
  => ctx
  -> { exception :: Error -> Aff a | r }
  -> Array (Om ctx err a)
  -> Event a
streamOms ctx handlers oms = 
  foldr (\om acc -> omToEvent ctx handlers om <|> acc) 
    empty
    oms

-- | Race multiple events, taking the first successful one
-- | Similar to Om's race but for events
raceEvents
  :: forall a
   . Array (Event a)
  -> Event a
raceEvents events = 
  foldr (<|>) 
    empty
    events

-- | Filter and map an Om computation based on event values
filterMapOm
  :: forall ctx r rl err_ err a b
   . RowToList (exception :: Error -> Aff (Maybe b) | r) rl
  => VariantMatchCases rl err_ (Aff (Maybe b))
  => Union err_ () (exception :: Error | err)
  => (a -> Om ctx err (Maybe b))
  -> ctx
  -> { exception :: Error -> Aff (Maybe b) | r }
  -> Event a
  -> Event b
filterMapOm f ctx handlers event = unsafePerformEffect do
  { event: outputEvent } <- makeEventE \push -> do
    _ <- liftST $ subscribe event \value -> do
      launchAff_ do
        result <- Om.runOm ctx handlers (f value)
        case result of
          Just b -> liftEffect $ push b
          Nothing -> pure unit
    pure $ pure unit
  pure outputEvent

-- | Fold over Om computations triggered by events
foldOms
  :: forall ctx r rl err_ err a b
   . RowToList (exception :: Error -> Aff b | r) rl
  => VariantMatchCases rl err_ (Aff b)
  => Union err_ () (exception :: Error | err)
  => (b -> a -> Om ctx err b)
  -> b
  -> ctx
  -> { exception :: Error -> Aff b | r }
  -> Event a
  -> Event b
foldOms f initial ctx handlers event = unsafePerformEffect do
  accRef <- Ref.new initial
  { event: outputEvent } <- makeEventE \push -> do
    _ <- liftST $ subscribe event \value -> do
      launchAff_ do
        currentAcc <- liftEffect $ Ref.read accRef
        newAcc <- Om.runOm ctx handlers (f currentAcc value)
        liftEffect do
          Ref.write newAcc accRef
          push newAcc
    pure $ pure unit
  pure outputEvent

-- | Helper to work with event streams within an Om context
-- | Provides a clean way to integrate event-driven logic
withEventStream
  :: forall ctx err a b
   . Event a
  -> (a -> Om ctx err b)
  -> Om ctx err (Event b)
withEventStream event f = do
  ctx <- Om.ask
  pure $ unsafePerformEffect do
    { event: outputEvent } <- makeEventE \push -> do
      _ <- liftST $ subscribe event \value -> do
        launchAff_ do
          -- Run the Om with basic error handling
          result <- Om.runReader ctx (f value)
          either (const $ pure unit) (\r -> liftEffect $ push r) result
      pure $ pure unit
    pure outputEvent