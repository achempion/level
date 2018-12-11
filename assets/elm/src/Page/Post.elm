module Page.Post exposing (Model, Msg(..), consumeEvent, init, receivePresence, setup, subscriptions, teardown, title, update, view)

import Browser.Navigation as Nav
import Component.Post
import Connection
import Event exposing (Event)
import Globals exposing (Globals)
import Group exposing (Group)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Id exposing (Id)
import Json.Decode as Decode
import Lazy exposing (Lazy(..))
import ListHelpers exposing (insertUniqueBy, removeBy)
import Mutation.ClosePost as ClosePost
import Mutation.DismissPosts as DismissPosts
import Mutation.MarkAsUnread as MarkAsUnread
import Mutation.RecordPostView as RecordPostView
import Mutation.RecordReplyViews as RecordReplyViews
import Mutation.ReopenPost as ReopenPost
import Post exposing (Post)
import PostEditor
import Presence exposing (Presence, PresenceList)
import Query.GetSpaceUser as GetSpaceUser
import Query.PostInit as PostInit
import Reply exposing (Reply)
import Repo exposing (Repo)
import Route exposing (Route)
import Session exposing (Session)
import Space exposing (Space)
import SpaceUser exposing (SpaceUser)
import SpaceUserLists exposing (SpaceUserLists)
import Task exposing (Task)
import TaskHelpers
import Time exposing (Posix, Zone, every)
import View.PresenceList
import View.SpaceLayout



-- MODEL


type alias Model =
    { spaceSlug : String
    , postId : Id
    , viewerId : Id
    , spaceId : Id
    , bookmarkIds : List Id
    , postComp : Component.Post.Model
    , now : ( Zone, Posix )
    , currentViewers : Lazy PresenceList
    , isChangingState : Bool
    , isChangingInboxState : Bool
    }


type alias Data =
    { viewer : SpaceUser
    , space : Space
    , bookmarks : List Group
    , post : Post
    }


resolveData : Repo -> Model -> Maybe Data
resolveData repo model =
    Maybe.map4 Data
        (Repo.getSpaceUser model.viewerId repo)
        (Repo.getSpace model.spaceId repo)
        (Just <| Repo.getGroups model.bookmarkIds repo)
        (Repo.getPost model.postId repo)



-- PAGE PROPERTIES


title : Model -> String
title model =
    "View post"


viewingTopic : Model -> String
viewingTopic { postComp } =
    "posts:" ++ postComp.id



-- LIFECYCLE


init : String -> Id -> Globals -> Task Session.Error ( Globals, Model )
init spaceSlug postId globals =
    globals.session
        |> PostInit.request spaceSlug postId
        |> TaskHelpers.andThenGetCurrentTime
        |> Task.map (buildModel spaceSlug globals)


buildModel : String -> Globals -> ( ( Session, PostInit.Response ), ( Zone, Posix ) ) -> ( Globals, Model )
buildModel spaceSlug globals ( ( newSession, resp ), now ) =
    let
        ( postId, replyIds ) =
            resp.postWithRepliesId

        postComp =
            Component.Post.init
                Component.Post.FullPage
                True
                spaceSlug
                postId
                replyIds

        model =
            Model
                spaceSlug
                postId
                resp.viewerId
                resp.spaceId
                resp.bookmarkIds
                postComp
                now
                NotLoaded
                False
                False

        newRepo =
            Repo.union resp.repo globals.repo
    in
    ( { globals | session = newSession, repo = newRepo }, model )


setup : Globals -> Model -> Cmd Msg
setup globals ({ postComp } as model) =
    Cmd.batch
        [ Cmd.map PostComponentMsg (Component.Post.setup postComp)
        , recordView globals.session model
        , recordReplyViews globals model
        , Presence.join (viewingTopic model)
        ]


teardown : Model -> Cmd Msg
teardown ({ postComp } as model) =
    Cmd.batch
        [ Cmd.map PostComponentMsg (Component.Post.teardown postComp)
        , Presence.leave (viewingTopic model)
        ]


recordView : Session -> Model -> Cmd Msg
recordView session model =
    let
        { nodes } =
            Connection.last 1 model.postComp.replyIds

        maybeReplyId =
            case nodes of
                [ lastReplyId ] ->
                    Just lastReplyId

                _ ->
                    Nothing
    in
    session
        |> RecordPostView.request model.spaceId model.postComp.id maybeReplyId
        |> Task.attempt ViewRecorded


recordReplyViews : Globals -> Model -> Cmd Msg
recordReplyViews globals model =
    let
        unviewedReplyIds =
            globals.repo
                |> Repo.getReplies (Connection.toList model.postComp.replyIds)
                |> List.filter (\reply -> not (Reply.hasViewed reply))
                |> List.map Reply.id
    in
    if List.length unviewedReplyIds > 0 then
        globals.session
            |> RecordReplyViews.request model.spaceId unviewedReplyIds
            |> Task.attempt ReplyViewsRecorded

    else
        Cmd.none



-- UPDATE


type Msg
    = NoOp
    | PostEditorEventReceived Decode.Value
    | PostComponentMsg Component.Post.Msg
    | ViewRecorded (Result Session.Error ( Session, RecordPostView.Response ))
    | ReplyViewsRecorded (Result Session.Error ( Session, RecordReplyViews.Response ))
    | Tick Posix
    | SetCurrentTime Posix Zone
    | SpaceUserFetched (Result Session.Error ( Session, GetSpaceUser.Response ))
    | ClosePostClicked
    | ReopenPostClicked
    | PostClosed (Result Session.Error ( Session, ClosePost.Response ))
    | PostReopened (Result Session.Error ( Session, ReopenPost.Response ))
    | DismissPostClicked
    | PostDismissed (Result Session.Error ( Session, DismissPosts.Response ))
    | MoveToInboxClicked
    | PostMovedToInbox (Result Session.Error ( Session, MarkAsUnread.Response ))
    | BackClicked


update : Msg -> Globals -> Model -> ( ( Model, Cmd Msg ), Globals )
update msg globals model =
    case msg of
        NoOp ->
            noCmd globals model

        PostEditorEventReceived value ->
            let
                newPostComp =
                    Component.Post.handleEditorEventReceived value model.postComp
            in
            ( ( { model | postComp = newPostComp }
              , Cmd.none
              )
            , globals
            )

        PostComponentMsg componentMsg ->
            let
                ( ( newPostComp, cmd ), newGlobals ) =
                    Component.Post.update componentMsg model.spaceId globals model.postComp
            in
            ( ( { model | postComp = newPostComp }
              , Cmd.map PostComponentMsg cmd
              )
            , newGlobals
            )

        ViewRecorded (Ok ( newSession, _ )) ->
            noCmd { globals | session = newSession } model

        ViewRecorded (Err Session.Expired) ->
            redirectToLogin globals model

        ViewRecorded (Err _) ->
            noCmd globals model

        ReplyViewsRecorded (Ok ( newSession, _ )) ->
            noCmd { globals | session = newSession } model

        ReplyViewsRecorded (Err Session.Expired) ->
            redirectToLogin globals model

        ReplyViewsRecorded (Err _) ->
            noCmd globals model

        Tick posix ->
            ( ( model, Task.perform (SetCurrentTime posix) Time.here ), globals )

        SetCurrentTime posix zone ->
            { model | now = ( zone, posix ) }
                |> noCmd globals

        SpaceUserFetched (Ok ( newSession, response )) ->
            let
                newRepo =
                    case response of
                        GetSpaceUser.Success spaceUser ->
                            Repo.setSpaceUser spaceUser globals.repo

                        _ ->
                            globals.repo
            in
            noCmd { globals | session = newSession, repo = newRepo } model

        SpaceUserFetched (Err Session.Expired) ->
            redirectToLogin globals model

        SpaceUserFetched (Err _) ->
            noCmd globals model

        ClosePostClicked ->
            let
                cmd =
                    globals.session
                        |> ClosePost.request model.spaceId model.postId
                        |> Task.attempt PostClosed
            in
            ( ( { model | isChangingState = True }, cmd ), globals )

        ReopenPostClicked ->
            let
                cmd =
                    globals.session
                        |> ReopenPost.request model.spaceId model.postId
                        |> Task.attempt PostReopened
            in
            ( ( { model | isChangingState = True }, cmd ), globals )

        PostClosed (Ok ( newSession, ClosePost.Success post )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setPost post
            in
            ( ( { model | isChangingState = False }, Cmd.none )
            , { globals | repo = newRepo, session = newSession }
            )

        PostClosed (Ok ( newSession, ClosePost.Invalid errors )) ->
            ( ( { model | isChangingState = False }, Cmd.none )
            , { globals | session = newSession }
            )

        PostClosed (Err Session.Expired) ->
            redirectToLogin globals model

        PostClosed (Err _) ->
            noCmd globals model

        PostReopened (Ok ( newSession, ReopenPost.Success post )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setPost post
            in
            ( ( { model | isChangingState = False }, Cmd.none )
            , { globals | repo = newRepo, session = newSession }
            )

        PostReopened (Ok ( newSession, ReopenPost.Invalid errors )) ->
            ( ( { model | isChangingState = False }, Cmd.none )
            , { globals | session = newSession }
            )

        PostReopened (Err Session.Expired) ->
            redirectToLogin globals model

        PostReopened (Err _) ->
            noCmd globals model

        DismissPostClicked ->
            let
                cmd =
                    globals.session
                        |> DismissPosts.request model.spaceId [ model.postId ]
                        |> Task.attempt PostDismissed
            in
            ( ( { model | isChangingInboxState = True }, cmd ), globals )

        PostDismissed (Ok ( newSession, _ )) ->
            ( ( { model | isChangingInboxState = False }, Cmd.none ), { globals | session = newSession } )

        PostDismissed (Err Session.Expired) ->
            redirectToLogin globals model

        PostDismissed (Err _) ->
            noCmd globals { model | isChangingInboxState = True }

        MoveToInboxClicked ->
            let
                cmd =
                    globals.session
                        |> MarkAsUnread.request model.spaceId [ model.postId ]
                        |> Task.attempt PostMovedToInbox
            in
            ( ( { model | isChangingInboxState = True }, cmd ), globals )

        PostMovedToInbox (Ok ( newSession, _ )) ->
            ( ( { model | isChangingInboxState = False }, Cmd.none ), { globals | session = newSession } )

        PostMovedToInbox (Err Session.Expired) ->
            redirectToLogin globals model

        PostMovedToInbox (Err _) ->
            noCmd globals { model | isChangingInboxState = True }

        BackClicked ->
            ( ( model, Nav.back globals.navKey 1 ), globals )


noCmd : Globals -> Model -> ( ( Model, Cmd Msg ), Globals )
noCmd globals model =
    ( ( model, Cmd.none ), globals )


redirectToLogin : Globals -> Model -> ( ( Model, Cmd Msg ), Globals )
redirectToLogin globals model =
    ( ( model, Route.toLogin ), globals )



-- INBOUND EVENTS


consumeEvent : Globals -> Event -> Model -> ( Model, Cmd Msg )
consumeEvent globals event model =
    case event of
        Event.GroupBookmarked group ->
            ( { model | bookmarkIds = insertUniqueBy identity (Group.id group) model.bookmarkIds }, Cmd.none )

        Event.GroupUnbookmarked group ->
            ( { model | bookmarkIds = removeBy identity (Group.id group) model.bookmarkIds }, Cmd.none )

        Event.ReplyCreated reply ->
            let
                ( newPostComp, cmd ) =
                    Component.Post.handleReplyCreated reply model.postComp

                viewCmd =
                    globals.session
                        |> RecordReplyViews.request model.spaceId [ Reply.id reply ]
                        |> Task.attempt ReplyViewsRecorded
            in
            ( { model | postComp = newPostComp }
            , Cmd.batch [ Cmd.map PostComponentMsg cmd, viewCmd ]
            )

        _ ->
            ( model, Cmd.none )


receivePresence : Presence.Event -> Globals -> Model -> ( Model, Cmd Msg )
receivePresence event globals model =
    case event of
        Presence.Sync topic list ->
            if topic == viewingTopic model then
                handleSync list model

            else
                ( model, Cmd.none )

        Presence.Join topic presence ->
            if topic == viewingTopic model then
                handleJoin presence globals model

            else
                ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


handleSync : PresenceList -> Model -> ( Model, Cmd Msg )
handleSync list model =
    ( { model | currentViewers = Loaded list }, Cmd.none )


handleJoin : Presence -> Globals -> Model -> ( Model, Cmd Msg )
handleJoin presence globals model =
    case Repo.getSpaceUserByUserId (Presence.getUserId presence) globals.repo of
        Just _ ->
            ( model, Cmd.none )

        Nothing ->
            ( model
            , globals.session
                |> GetSpaceUser.request model.spaceId (Presence.getUserId presence)
                |> Task.attempt SpaceUserFetched
            )



-- SUBSCRIPTIONS


subscriptions : Sub Msg
subscriptions =
    Sub.batch
        [ every 1000 Tick
        , PostEditor.receive PostEditorEventReceived
        ]



-- VIEW


view : Repo -> Maybe Route -> SpaceUserLists -> Model -> Html Msg
view repo maybeCurrentRoute spaceUserLists model =
    let
        spaceUsers =
            SpaceUserLists.resolveList repo model.spaceId spaceUserLists
    in
    case resolveData repo model of
        Just data ->
            resolvedView repo maybeCurrentRoute spaceUsers model data

        Nothing ->
            text "Something went wrong."


resolvedView : Repo -> Maybe Route -> List SpaceUser -> Model -> Data -> Html Msg
resolvedView repo maybeCurrentRoute spaceUsers model data =
    View.SpaceLayout.layout
        data.viewer
        data.space
        data.bookmarks
        maybeCurrentRoute
        [ div [ class "mx-auto max-w-90 leading-normal" ]
            [ postView repo spaceUsers model data
            , sidebarView repo model data
            ]
        ]


postView : Repo -> List SpaceUser -> Model -> Data -> Html Msg
postView repo spaceUsers model data =
    div []
        [ div [ class "sticky pin-t mb-6 py-2 border-b bg-white z-10" ]
            [ button
                [ class "btn btn-md btn-dusty-blue-inverse text-base"
                , onClick BackClicked
                ]
                [ text "Back" ]
            , inboxStateButton model.isChangingInboxState data.post
            , postStateButton model.isChangingState data.post
            ]
        , model.postComp
            |> Component.Post.view repo data.space data.viewer model.now spaceUsers
            |> Html.map PostComponentMsg
        ]


inboxStateButton : Bool -> Post -> Html Msg
inboxStateButton isChangingInboxState post =
    case Post.inboxState post of
        Post.Excluded ->
            button
                [ class "btn btn-md btn-dusty-blue-inverse text-base"
                , onClick MoveToInboxClicked
                , disabled isChangingInboxState
                ]
                [ text "Add to my inbox" ]

        Post.Unread ->
            button
                [ class "btn btn-md btn-dusty-blue-inverse text-base"
                , onClick DismissPostClicked
                , disabled isChangingInboxState
                ]
                [ text "Dismiss from my inbox" ]

        Post.Read ->
            button
                [ class "btn btn-md btn-dusty-blue-inverse text-base"
                , onClick DismissPostClicked
                , disabled isChangingInboxState
                ]
                [ text "Dismiss from my inbox" ]

        Post.Dismissed ->
            button
                [ class "btn btn-md btn-dusty-blue-inverse text-base"
                , onClick MoveToInboxClicked
                , disabled isChangingInboxState
                ]
                [ text "Add to my inbox" ]


postStateButton : Bool -> Post -> Html Msg
postStateButton isChangingState post =
    case Post.state post of
        Post.Open ->
            button
                [ class "btn btn-md btn-dusty-blue-inverse text-base"
                , onClick ClosePostClicked
                , disabled isChangingState
                ]
                [ text "Mark as resolved" ]

        Post.Closed ->
            button
                [ class "btn btn-md btn-dusty-blue-inverse text-base"
                , onClick ReopenPostClicked
                , disabled isChangingState
                ]
                [ text "Mark as open" ]


sidebarView : Repo -> Model -> Data -> Html Msg
sidebarView repo model data =
    let
        listView =
            case model.currentViewers of
                Loaded state ->
                    View.PresenceList.view repo data.space state

                NotLoaded ->
                    div [ class "pb-4 text-sm" ] [ text "Loading..." ]
    in
    View.SpaceLayout.rightSidebar
        [ h3 [ class "mb-2 text-base font-extrabold" ] [ text "Who’s Here" ]
        , listView
        ]
