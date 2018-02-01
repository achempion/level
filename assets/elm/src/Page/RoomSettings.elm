module Page.RoomSettings exposing (Model, ExternalMsg(..), Msg, fetchRoom, buildModel, update, subscriptions, view)

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onInput, onClick)
import Http
import Keyboard
import Task exposing (Task)
import Data.Room exposing (Room)
import Session exposing (Session)
import Data.User exposing (UserConnection)
import Data.ValidationError exposing (ValidationError, errorsFor)
import Mutation.UpdateRoom as UpdateRoom
import Query.RoomSettings
import Color
import Icons exposing (closeIcon, peopleIcon)
import Route
import Util exposing (onEnter)


-- MODEL


type alias Model =
    { id : String
    , name : String
    , description : String
    , subscriberPolicy : Data.Room.SubscriberPolicy
    , isSubmitting : Bool
    , errors : List ValidationError
    , users : UserConnection
    }


{-| Builds a Task to fetch a room by slug.
-}
fetchRoom : Session -> String -> Task Http.Error Query.RoomSettings.Response
fetchRoom session slug =
    Query.RoomSettings.request session (Query.RoomSettings.Params slug)
        |> Http.toTask


{-| Builds the initial model for the page.
-}
buildModel : Room -> UserConnection -> Model
buildModel room users =
    Model room.id room.name room.description room.subscriberPolicy False [] users


{-| Determines whether the form is able to be submitted.
-}
isSubmittable : Model -> Bool
isSubmittable model =
    model.isSubmitting == False



-- UPDATE


type Msg
    = NameChanged String
    | DescriptionChanged String
    | PrivacyToggled
    | Submit
    | Submitted (Result Http.Error UpdateRoom.Response)
    | Keydown Keyboard.KeyCode


type ExternalMsg
    = RoomUpdated Room
    | NoOp


update : Msg -> Session -> Model -> ( ( Model, Cmd Msg ), ExternalMsg )
update msg session model =
    case msg of
        NameChanged val ->
            ( ( { model | name = val }, Cmd.none ), NoOp )

        DescriptionChanged val ->
            ( ( { model | description = val }, Cmd.none ), NoOp )

        PrivacyToggled ->
            if model.subscriberPolicy == Data.Room.InviteOnly then
                ( ( { model | subscriberPolicy = Data.Room.Public }, Cmd.none ), NoOp )
            else
                ( ( { model | subscriberPolicy = Data.Room.InviteOnly }, Cmd.none ), NoOp )

        Submit ->
            let
                request =
                    UpdateRoom.request session <|
                        UpdateRoom.Params model.id model.name model.description model.subscriberPolicy
            in
                if isSubmittable model then
                    ( ( { model | isSubmitting = True }
                      , Http.send Submitted request
                      )
                    , NoOp
                    )
                else
                    ( ( model, Cmd.none ), NoOp )

        Submitted (Ok (UpdateRoom.Success room)) ->
            ( ( { model | isSubmitting = False }, navigateToRoom model ), RoomUpdated room )

        Submitted (Ok (UpdateRoom.Invalid errors)) ->
            ( ( { model | errors = errors, isSubmitting = False }, Cmd.none ), NoOp )

        Submitted (Err _) ->
            -- TODO: something unexpected went wrong - figure out best way to handle?
            ( ( { model | isSubmitting = False }, Cmd.none ), NoOp )

        Keydown code ->
            case code of
                -- esc
                27 ->
                    ( ( model, navigateToRoom model ), NoOp )

                _ ->
                    ( ( model, Cmd.none ), NoOp )


navigateToRoom : Model -> Cmd Msg
navigateToRoom model =
    Route.modifyUrl <| Route.Room model.id



-- SUBSCRIPTIONS


subscriptions : Sub Msg
subscriptions =
    Keyboard.downs Keydown



-- VIEW


view : Model -> Html Msg
view model =
    div [ id "main", class "main" ]
        [ div [ class "page-head page-head--borderless" ]
            [ div [ class "page-head__header" ]
                [ div [ class "page-head__title" ] []
                , div [ class "page-head__controls" ]
                    [ a [ Route.href (Route.Room model.id), class "button button--secondary" ]
                        [ closeIcon (Color.rgb 144 150 162) 24
                        ]
                    ]
                ]
            ]
        , div [ class "cform cform--slim-pad" ]
            [ div [ class "cform__header" ]
                [ h2 [ class "cform__heading" ] [ text "Room Settings" ]
                , div [ class "cform__description" ] [ text "Customize this room to your liking and configure your desired privacy settings." ]
                ]
            , div [ class "cform__form" ]
                [ inputField "name" "Room Name" model.name NameChanged model
                , inputField "description" "Description" model.description DescriptionChanged model
                , privacyField model
                , div [ class "form-controls" ]
                    [ input
                        [ type_ "submit"
                        , value "Save Settings"
                        , class "button button--primary button--large"
                        , disabled (not <| isSubmittable model)
                        , onClick Submit
                        ]
                        []
                    ]
                ]
            ]
        ]


inputField : String -> String -> String -> (String -> Msg) -> Model -> Html Msg
inputField fieldName labelText fieldValue inputMsg model =
    let
        errors =
            errorsFor fieldName model.errors
    in
        div
            [ classList
                [ ( "form-field", True )
                , ( "form-field--error", not (List.isEmpty errors) )
                ]
            ]
            [ label [ class "form-label" ] [ text labelText ]
            , input
                [ type_ "text"
                , id (fieldName ++ "-field")
                , class "text-field text-field--full text-field--large"
                , name fieldName
                , value fieldValue
                , onInput inputMsg
                , onEnter Submit
                , disabled model.isSubmitting
                ]
                []
            , formErrors errors
            ]


privacyField : Model -> Html Msg
privacyField model =
    case model.subscriberPolicy of
        Data.Room.Mandatory ->
            div [ class "form-info" ]
                [ peopleIcon (Color.rgb 144 150 162) 24
                , text "Everyone joins this room by default."
                ]

        _ ->
            div [ class "form-field" ]
                [ div [ class "checkbox-toggle" ]
                    [ input
                        [ type_ "checkbox"
                        , id "private"
                        , checked (model.subscriberPolicy == Data.Room.InviteOnly)
                        , onClick PrivacyToggled
                        ]
                        []
                    , label [ class "checkbox-toggle__label", for "private" ]
                        [ span [ class "checkbox-toggle__switch" ] []
                        , text "Private (by invite only)"
                        ]
                    ]
                ]


formErrors : List ValidationError -> Html Msg
formErrors errors =
    case errors of
        error :: _ ->
            div [ class "form-errors" ] [ text error.message ]

        [] ->
            text ""
