module SchemaUtils exposing
    ( OneOfName
    , decodeOptionalField
    , decodeOptionalFieldDocumentation
    , getAlias
    , oneOfDeclarations
    , recordType
    , refToTypeName
    , schemaToType
    , toVariantName
    , typeToAnnotationWithMaybe
    , typeToAnnotationWithNullable
    , typeToDecoder
    , typeToEncoder
    )

import CliMonad exposing (CliMonad)
import Common
import Dict
import Elm
import Elm.Annotation
import Elm.Case
import Elm.Declare
import Elm.Op
import Elm.ToString
import FastDict
import Gen.Basics
import Gen.Bytes
import Gen.Date
import Gen.Json.Decode
import Gen.Json.Encode
import Gen.List
import Gen.Maybe
import Gen.OpenApi.Common
import Gen.Parser.Advanced
import Gen.Result
import Gen.Rfc3339
import Gen.Time
import Json.Decode
import Json.Encode
import Json.Schema.Definitions
import Maybe.Extra
import OpenApi
import OpenApi.Components
import OpenApi.Schema
import Result.Extra
import Set exposing (Set)


getSchema : String -> CliMonad Json.Schema.Definitions.Schema
getSchema refName =
    CliMonad.fromApiSpec identity
        |> CliMonad.stepOrFail ("Could not find components in the schema, while looking up" ++ refName)
            OpenApi.components
        |> CliMonad.stepOrFail ("Could not find component's schema, while looking up" ++ refName)
            (\components -> Dict.get refName (OpenApi.Components.schemas components))
        |> CliMonad.map OpenApi.Schema.get


getAlias : List String -> CliMonad Json.Schema.Definitions.Schema
getAlias refUri =
    case refUri of
        [ "#", "components", _, name ] ->
            getSchema name

        _ ->
            CliMonad.fail <| "Couldn't get the type ref (" ++ String.join "/" refUri ++ ") for the response"


schemaToProperties : Bool -> Json.Schema.Definitions.Schema -> CliMonad (List ( Common.UnsafeName, Common.Field ))
schemaToProperties qualify allOfItem =
    case allOfItem of
        Json.Schema.Definitions.ObjectSchema allOfItemSchema ->
            CliMonad.map2 listUnion
                (subSchemaToProperties qualify allOfItemSchema)
                (subSchemaRefToProperties qualify allOfItemSchema)

        Json.Schema.Definitions.BooleanSchema _ ->
            CliMonad.todoWithDefault [] "Boolean schema inside allOf"


listUnion : List ( Common.UnsafeName, a ) -> List ( Common.UnsafeName, a ) -> List ( Common.UnsafeName, a )
listUnion l r =
    let
        toDict : List ( Common.UnsafeName, b ) -> FastDict.Dict String b
        toDict v =
            FastDict.fromList (List.map (Tuple.mapFirst Common.unwrapUnsafe) v)
    in
    FastDict.union (toDict l) (toDict r)
        |> FastDict.toList
        |> List.map (Tuple.mapFirst Common.UnsafeName)


subSchemaRefToProperties : Bool -> Json.Schema.Definitions.SubSchema -> CliMonad (List ( Common.UnsafeName, Common.Field ))
subSchemaRefToProperties qualify allOfItem =
    case allOfItem.ref of
        Nothing ->
            CliMonad.succeed []

        Just ref ->
            getAlias (String.split "/" ref)
                |> CliMonad.withPath (Common.UnsafeName ref)
                |> CliMonad.andThen (schemaToProperties qualify)


subSchemaToProperties : Bool -> Json.Schema.Definitions.SubSchema -> CliMonad (List ( Common.UnsafeName, Common.Field ))
subSchemaToProperties qualify sch =
    -- TODO: rename
    let
        requiredSet : Set String
        requiredSet =
            sch.required
                |> Maybe.withDefault []
                |> Set.fromList
    in
    sch.properties
        |> Maybe.map (\(Json.Schema.Definitions.Schemata schemata) -> schemata)
        |> Maybe.withDefault []
        |> CliMonad.combineMap
            (\( key, valueSchema ) ->
                schemaToType qualify valueSchema
                    |> CliMonad.withPath (Common.UnsafeName key)
                    |> CliMonad.map
                        (\{ type_, documentation } ->
                            ( Common.UnsafeName key
                            , { type_ = type_
                              , required = Set.member key requiredSet
                              , documentation = documentation
                              }
                            )
                        )
            )


schemaToType : Bool -> Json.Schema.Definitions.Schema -> CliMonad { type_ : Common.Type, documentation : Maybe String }
schemaToType qualify schema =
    case schema of
        Json.Schema.Definitions.BooleanSchema _ ->
            CliMonad.todoWithDefault { type_ = Common.Value, documentation = Nothing } "Boolean schema"

        Json.Schema.Definitions.ObjectSchema subSchema ->
            let
                nullable : CliMonad { type_ : Common.Type, documentation : Maybe String } -> CliMonad { type_ : Common.Type, documentation : Maybe String }
                nullable =
                    CliMonad.map
                        (\{ type_, documentation } ->
                            { type_ = Common.Nullable type_
                            , documentation = documentation
                            }
                        )

                singleTypeToType : Json.Schema.Definitions.SingleType -> CliMonad { type_ : Common.Type, documentation : Maybe String }
                singleTypeToType singleType =
                    let
                        getConstAs : Json.Decode.Decoder a -> CliMonad (Maybe a)
                        getConstAs decoder =
                            case subSchema.const of
                                Nothing ->
                                    CliMonad.succeed Nothing

                                Just const ->
                                    case Json.Decode.decodeValue decoder const of
                                        Ok value ->
                                            CliMonad.succeed (Just value)

                                        Err _ ->
                                            CliMonad.fail ("Invalid const value: " ++ Json.Encode.encode 0 const)
                    in
                    case singleType of
                        Json.Schema.Definitions.ObjectType ->
                            objectSchemaToType qualify subSchema

                        Json.Schema.Definitions.StringType ->
                            getConstAs Json.Decode.string
                                |> CliMonad.andThen
                                    (\const ->
                                        case subSchema.format of
                                            Just "date-time" ->
                                                CliMonad.succeed { type_ = Common.DateTime, documentation = subSchema.description }

                                            Just "date" ->
                                                CliMonad.succeed { type_ = Common.Date, documentation = subSchema.description }

                                            Just "password" ->
                                                { type_ = Common.String { const = const }
                                                , documentation = subSchema.description
                                                }
                                                    |> CliMonad.succeed

                                            Just format ->
                                                { type_ = Common.String { const = const }
                                                , documentation = subSchema.description
                                                }
                                                    |> CliMonad.succeed
                                                    |> CliMonad.withWarning ("Format \"" ++ format ++ "\" not supported - using string instead")

                                            Nothing ->
                                                CliMonad.succeed { type_ = Common.String { const = const }, documentation = subSchema.description }
                                    )

                        Json.Schema.Definitions.IntegerType ->
                            getConstAs Json.Decode.int
                                |> CliMonad.map
                                    (\const ->
                                        { type_ = Common.Int { const = const }, documentation = subSchema.description }
                                    )

                        Json.Schema.Definitions.NumberType ->
                            getConstAs Json.Decode.float
                                |> CliMonad.map
                                    (\const ->
                                        { type_ = Common.Float { const = const }, documentation = subSchema.description }
                                    )

                        Json.Schema.Definitions.BooleanType ->
                            getConstAs Json.Decode.bool
                                |> CliMonad.map
                                    (\const ->
                                        { type_ = Common.Bool { const = const }, documentation = subSchema.description }
                                    )

                        Json.Schema.Definitions.NullType ->
                            CliMonad.succeed { type_ = Common.Null, documentation = subSchema.description }

                        Json.Schema.Definitions.ArrayType ->
                            case subSchema.items of
                                Json.Schema.Definitions.NoItems ->
                                    CliMonad.fail "Found an array type but no items definition"

                                Json.Schema.Definitions.ArrayOfItems _ ->
                                    CliMonad.todoWithDefault { type_ = Common.Value, documentation = subSchema.description } "Array of items as item definition"

                                Json.Schema.Definitions.ItemDefinition itemSchema ->
                                    CliMonad.map
                                        (\{ type_, documentation } ->
                                            { type_ = Common.List type_
                                            , documentation =
                                                [ subSchema.description
                                                , Maybe.map
                                                    (\doc ->
                                                        if String.contains "\n" doc then
                                                            "A list of:\n" ++ doc

                                                        else
                                                            "A list of: " ++ doc
                                                    )
                                                    documentation
                                                ]
                                                    |> joinIfNotEmpty "\n\n"
                                            }
                                        )
                                        (schemaToType qualify itemSchema)

                anyOfToType : List Json.Schema.Definitions.Schema -> CliMonad { type_ : Common.Type, documentation : Maybe String }
                anyOfToType _ =
                    CliMonad.succeed { type_ = Common.Value, documentation = subSchema.description }

                oneOfToType : List Json.Schema.Definitions.Schema -> CliMonad { type_ : Common.Type, documentation : Maybe String }
                oneOfToType oneOf =
                    CliMonad.combineMap (schemaToType qualify) oneOf
                        |> CliMonad.andThen oneOfType
                        |> CliMonad.map
                            (\{ type_, documentation } ->
                                { type_ = type_
                                , documentation =
                                    [ subSchema.description
                                    , documentation
                                    ]
                                        |> joinIfNotEmpty "\n\n"
                                }
                            )
            in
            case subSchema.type_ of
                Json.Schema.Definitions.SingleType Json.Schema.Definitions.StringType ->
                    case subSchema.enum of
                        Nothing ->
                            singleTypeToType Json.Schema.Definitions.StringType

                        Just enums ->
                            case Result.Extra.combineMap (Json.Decode.decodeValue Json.Decode.string) enums of
                                Err _ ->
                                    CliMonad.fail "Attempted to parse an enum as a string and failed"

                                Ok decodedEnums ->
                                    CliMonad.succeed
                                        { type_ = Common.enum decodedEnums
                                        , documentation = subSchema.description
                                        }

                Json.Schema.Definitions.SingleType singleType ->
                    singleTypeToType singleType

                Json.Schema.Definitions.AnyType ->
                    case subSchema.ref of
                        Just ref ->
                            CliMonad.succeed { type_ = Common.ref ref, documentation = subSchema.description }

                        Nothing ->
                            case subSchema.anyOf of
                                Just [ onlySchema ] ->
                                    schemaToType qualify onlySchema

                                Just [ firstSchema, secondSchema ] ->
                                    case ( firstSchema, secondSchema ) of
                                        ( Json.Schema.Definitions.ObjectSchema firstSubSchema, Json.Schema.Definitions.ObjectSchema secondSubSchema ) ->
                                            -- The first 2 cases here are for pseudo-nullable schemas where the higher level schema type is AnyOf
                                            -- but it's actually made up of only 2 types and 1 of them is nullable. This acts as a hack of sorts to
                                            -- mark a value as nullable in the schema.
                                            case ( firstSubSchema.type_, secondSubSchema.type_ ) of
                                                ( Json.Schema.Definitions.SingleType Json.Schema.Definitions.NullType, _ ) ->
                                                    nullable (schemaToType qualify secondSchema)

                                                ( _, Json.Schema.Definitions.SingleType Json.Schema.Definitions.NullType ) ->
                                                    nullable (schemaToType qualify firstSchema)

                                                _ ->
                                                    anyOfToType [ firstSchema, secondSchema ]

                                        _ ->
                                            anyOfToType [ firstSchema, secondSchema ]

                                Just anyOf ->
                                    anyOfToType anyOf

                                Nothing ->
                                    case subSchema.allOf of
                                        Just [ onlySchema ] ->
                                            schemaToType qualify onlySchema

                                        Just [] ->
                                            CliMonad.succeed { type_ = Common.Value, documentation = subSchema.description }

                                        Just _ ->
                                            -- If we have more than one item in `allOf`, then it's _probably_ an object
                                            -- TODO: improve this to actually check if all the `allOf` subschema are objects.
                                            objectSchemaToType qualify subSchema

                                        Nothing ->
                                            case subSchema.oneOf of
                                                Just [ onlySchema ] ->
                                                    schemaToType qualify onlySchema

                                                Just [] ->
                                                    CliMonad.succeed { type_ = Common.Value, documentation = subSchema.description }

                                                Just oneOfs ->
                                                    oneOfToType oneOfs

                                                Nothing ->
                                                    case subSchema.enum of
                                                        Nothing ->
                                                            CliMonad.succeed { type_ = Common.Value, documentation = subSchema.description }

                                                        Just enums ->
                                                            case Result.Extra.combineMap (Json.Decode.decodeValue Json.Decode.string) enums of
                                                                Err _ ->
                                                                    CliMonad.fail "Attempted to parse an enum as a string and failed"

                                                                Ok decodedEnums ->
                                                                    CliMonad.succeed
                                                                        { type_ = Common.enum decodedEnums
                                                                        , documentation = subSchema.description
                                                                        }

                Json.Schema.Definitions.NullableType singleType ->
                    nullable (singleTypeToType singleType)

                Json.Schema.Definitions.UnionType singleTypes ->
                    let
                        ( nulls, nonNulls ) =
                            List.partition
                                (\st -> st == Json.Schema.Definitions.NullType)
                                singleTypes
                    in
                    nonNulls
                        |> CliMonad.combineMap singleTypeToType
                        |> CliMonad.andThen oneOfType
                        |> CliMonad.map
                            (\{ type_, documentation } ->
                                { type_ =
                                    if List.isEmpty nulls then
                                        type_

                                    else
                                        Common.Nullable type_
                                , documentation = documentation
                                }
                            )


typeToOneOfVariant :
    Bool
    -> { type_ : Common.Type, documentation : Maybe String }
    -> CliMonad (Maybe { name : Common.UnsafeName, type_ : Common.Type, documentation : Maybe String })
typeToOneOfVariant qualify { type_, documentation } =
    type_
        |> typeToAnnotationWithNullable qualify
        |> CliMonad.map
            (\ann ->
                let
                    rawName : String
                    rawName =
                        ann
                            |> Elm.ToString.annotation
                            |> .signature
                in
                if String.contains "{" rawName then
                    Nothing

                else
                    Just
                        { name = Common.UnsafeName rawName
                        , type_ = type_
                        , documentation = documentation
                        }
            )


oneOfType :
    List { type_ : Common.Type, documentation : Maybe String }
    -> CliMonad { type_ : Common.Type, documentation : Maybe String }
oneOfType types =
    types
        |> CliMonad.combineMap (typeToOneOfVariant False)
        |> CliMonad.map
            (\maybeVariants ->
                case Maybe.Extra.combine maybeVariants of
                    Nothing ->
                        { type_ = Common.Value, documentation = Nothing }

                    Just variants ->
                        let
                            sortedVariants :
                                List
                                    { name : Common.UnsafeName
                                    , type_ : Common.Type
                                    , documentation : Maybe String
                                    }
                            sortedVariants =
                                List.sortBy (\{ name } -> Common.unwrapUnsafe name) variants

                            names : List Common.UnsafeName
                            names =
                                List.map .name sortedVariants
                        in
                        { type_ =
                            Common.OneOf
                                (names
                                    |> List.map fixOneOfName
                                    |> String.join "_Or_"
                                )
                                sortedVariants
                        , documentation =
                            sortedVariants
                                |> List.map (\{ name, documentation } -> Maybe.map (\doc -> " - " ++ Common.toValueName name ++ ": " ++ doc) documentation)
                                |> joinIfNotEmpty "\n\n"
                                |> Maybe.map (\doc -> "This is a oneOf. The alternatives are:\n\n" ++ doc)
                        }
            )


objectSchemaToType : Bool -> Json.Schema.Definitions.SubSchema -> CliMonad { type_ : Common.Type, documentation : Maybe String }
objectSchemaToType qualify subSchema =
    let
        propertiesFromAllOf : CliMonad (List ( Common.UnsafeName, Common.Field ))
        propertiesFromAllOf =
            subSchema.allOf
                |> Maybe.withDefault []
                |> CliMonad.combineMap (schemaToProperties qualify)
                |> CliMonad.map (List.foldl listUnion [])
    in
    CliMonad.map2
        (\schemaProps allOfProps ->
            let
                ( props, propsDocumentations ) =
                    listUnion schemaProps allOfProps
                        |> List.map
                            (\( name, field ) ->
                                ( ( name, field )
                                , field.documentation
                                    |> Maybe.map
                                        (\doc ->
                                            " - " ++ Common.toValueName name ++ ": " ++ String.join "\n      " (String.split "\n" doc)
                                        )
                                )
                            )
                        |> List.unzip

                propsDocumentation : Maybe String
                propsDocumentation =
                    propsDocumentations
                        |> joinIfNotEmpty "\n"
            in
            { type_ = Common.Object props
            , documentation =
                case propsDocumentation of
                    Nothing ->
                        subSchema.description

                    Just _ ->
                        [ Just (Maybe.withDefault "Fields:" subSchema.description) -- A nonempty line is needed for formatting
                        , propsDocumentation
                        ]
                            |> joinIfNotEmpty "\n\n"
            }
        )
        (subSchemaToProperties qualify subSchema)
        propertiesFromAllOf


joinIfNotEmpty : String -> List (Maybe String) -> Maybe String
joinIfNotEmpty sep chunks =
    let
        filtered : List String
        filtered =
            List.filterMap identity chunks
    in
    if List.isEmpty filtered then
        Nothing

    else
        Just (String.join sep filtered)


type alias OneOfName =
    Common.TypeName


oneOfDeclarations :
    FastDict.Dict OneOfName Common.OneOfData
    -> CliMonad (List ( Common.Module, Elm.Declaration ))
oneOfDeclarations enums =
    CliMonad.combineMap
        oneOfDeclaration
        (FastDict.toList enums)


oneOfDeclaration :
    ( OneOfName, Common.OneOfData )
    -> CliMonad ( Common.Module, Elm.Declaration )
oneOfDeclaration ( oneOfName, variants ) =
    let
        variantDeclaration : { name : Common.UnsafeName, type_ : Common.Type, documentation : Maybe String } -> CliMonad Elm.Variant
        variantDeclaration { name, type_ } =
            typeToAnnotationWithNullable False type_
                |> CliMonad.map
                    (\variantAnnotation ->
                        let
                            variantName : Common.VariantName
                            variantName =
                                toVariantName oneOfName name
                        in
                        Elm.variantWith variantName [ variantAnnotation ]
                    )
    in
    variants
        |> CliMonad.combineMap variantDeclaration
        |> CliMonad.map
            (\decl ->
                ( Common.Types
                , decl
                    |> Elm.customType oneOfName
                    |> Elm.exposeWith
                        { exposeConstructor = True
                        , group = Just "One of"
                        }
                )
            )


toVariantName : Common.TypeName -> Common.UnsafeName -> String
toVariantName oneOfName variantName =
    oneOfName ++ "__" ++ fixOneOfName variantName


{-| When we go from `Elm.Annotation` to `String` it includes the module name if it's an imported type.
We don't want that for our generated types, so we remove it here.
-}
fixOneOfName : Common.UnsafeName -> String
fixOneOfName name =
    name
        |> Common.unwrapUnsafe
        |> String.replace "OpenApi.Nullable" "Nullable"
        |> String.replace "." ""
        |> Common.UnsafeName
        |> Common.toTypeName


{-| Transform an OpenAPI type into an Elm annotation. Nullable values are represented using Nullable.
-}
typeToAnnotationWithNullable : Bool -> Common.Type -> CliMonad Elm.Annotation.Annotation
typeToAnnotationWithNullable qualify type_ =
    case type_ of
        Common.Nullable t ->
            CliMonad.map
                Gen.OpenApi.Common.annotation_.nullable
                (typeToAnnotationWithNullable qualify t)

        Common.Object fields ->
            objectToAnnotation qualify { useMaybe = False } fields

        Common.String _ ->
            CliMonad.succeed Elm.Annotation.string

        Common.DateTime ->
            CliMonad.succeed Gen.Time.annotation_.posix

        Common.Date ->
            CliMonad.succeed Gen.Date.annotation_.date

        Common.Int _ ->
            CliMonad.succeed Elm.Annotation.int

        Common.Float _ ->
            CliMonad.succeed Elm.Annotation.float

        Common.Bool _ ->
            CliMonad.succeed Elm.Annotation.bool

        Common.Null ->
            CliMonad.succeed Elm.Annotation.unit

        Common.List t ->
            CliMonad.map Elm.Annotation.list (typeToAnnotationWithNullable qualify t)

        Common.Enum variants ->
            CliMonad.enumName variants
                |> CliMonad.andThen
                    (\maybeName ->
                        case maybeName of
                            Nothing ->
                                CliMonad.succeed Elm.Annotation.string

                            Just name ->
                                CliMonad.map
                                    (\typesNamespace ->
                                        if qualify then
                                            Elm.Annotation.named typesNamespace (Common.toTypeName name)

                                        else
                                            Elm.Annotation.named [] (Common.toTypeName name)
                                    )
                                    (CliMonad.moduleToNamespace Common.Types)
                    )

        Common.OneOf oneOfName oneOfData ->
            oneOfAnnotation qualify oneOfName oneOfData

        Common.Value ->
            CliMonad.succeed Gen.Json.Encode.annotation_.value

        Common.Ref ref ->
            CliMonad.map2
                (\typesNamespace name ->
                    if qualify then
                        Elm.Annotation.named typesNamespace (Common.toTypeName name)

                    else
                        Elm.Annotation.named [] (Common.toTypeName name)
                )
                (CliMonad.moduleToNamespace Common.Types)
                (refToTypeName ref)

        Common.Bytes ->
            CliMonad.succeed Gen.Bytes.annotation_.bytes

        Common.Unit ->
            CliMonad.succeed Elm.Annotation.unit


{-| Transform an OpenAPI type into an Elm annotation. Nullable values are represented using Maybe.
-}
typeToAnnotationWithMaybe : Bool -> Common.Type -> CliMonad Elm.Annotation.Annotation
typeToAnnotationWithMaybe qualify type_ =
    case type_ of
        Common.Nullable t ->
            CliMonad.map Elm.Annotation.maybe (typeToAnnotationWithMaybe qualify t)

        Common.Object fields ->
            objectToAnnotation qualify { useMaybe = True } fields

        Common.String _ ->
            CliMonad.succeed Elm.Annotation.string

        Common.DateTime ->
            CliMonad.succeed Gen.Time.annotation_.posix

        Common.Date ->
            CliMonad.succeed Gen.Date.annotation_.date

        Common.Int _ ->
            CliMonad.succeed Elm.Annotation.int

        Common.Float _ ->
            CliMonad.succeed Elm.Annotation.float

        Common.Bool _ ->
            CliMonad.succeed Elm.Annotation.bool

        Common.Null ->
            CliMonad.succeed Elm.Annotation.unit

        Common.List t ->
            CliMonad.map Elm.Annotation.list (typeToAnnotationWithMaybe qualify t)

        Common.Enum variants ->
            CliMonad.enumName variants
                |> CliMonad.andThen
                    (\maybeName ->
                        case maybeName of
                            Nothing ->
                                CliMonad.succeed Elm.Annotation.string

                            Just name ->
                                CliMonad.map
                                    (\typesNamespace ->
                                        if qualify then
                                            Elm.Annotation.named typesNamespace (Common.toTypeName name)

                                        else
                                            Elm.Annotation.named [] (Common.toTypeName name)
                                    )
                                    (CliMonad.moduleToNamespace Common.Types)
                    )

        Common.OneOf oneOfName oneOfData ->
            oneOfAnnotation qualify oneOfName oneOfData

        Common.Value ->
            CliMonad.succeed Gen.Json.Encode.annotation_.value

        Common.Ref ref ->
            CliMonad.map2
                (\typesNamespace name ->
                    if qualify then
                        Elm.Annotation.named typesNamespace (Common.toTypeName name)

                    else
                        Elm.Annotation.named [] (Common.toTypeName name)
                )
                (CliMonad.moduleToNamespace Common.Types)
                (refToTypeName ref)

        Common.Bytes ->
            CliMonad.succeed Gen.Bytes.annotation_.bytes

        Common.Unit ->
            CliMonad.succeed Elm.Annotation.unit


objectToAnnotation : Bool -> { useMaybe : Bool } -> Common.Object -> CliMonad Elm.Annotation.Annotation
objectToAnnotation qualify config fields =
    fields
        |> CliMonad.combineMap (\( k, v ) -> CliMonad.map (Tuple.pair k) (fieldToAnnotation qualify config v))
        |> CliMonad.map recordType


recordType : List ( Common.UnsafeName, Elm.Annotation.Annotation ) -> Elm.Annotation.Annotation
recordType fields =
    fields
        |> List.map (Tuple.mapFirst Common.toValueName)
        |> Elm.Annotation.record


fieldToAnnotation : Bool -> { useMaybe : Bool } -> Common.Field -> CliMonad Elm.Annotation.Annotation
fieldToAnnotation qualify { useMaybe } { type_, required } =
    let
        annotation : CliMonad Elm.Annotation.Annotation
        annotation =
            if useMaybe then
                typeToAnnotationWithMaybe qualify type_

            else
                typeToAnnotationWithNullable qualify type_
    in
    if required then
        annotation

    else
        CliMonad.map Gen.Maybe.annotation_.maybe annotation


typeToEncoder : Bool -> Common.Type -> CliMonad (Elm.Expression -> Elm.Expression)
typeToEncoder qualify type_ =
    case type_ of
        Common.String _ ->
            CliMonad.succeed Gen.Json.Encode.call_.string

        Common.DateTime ->
            CliMonad.succeed
                (\instant ->
                    Gen.Rfc3339.make_.dateTimeOffset
                        (Elm.record
                            [ ( "instant", instant )
                            , ( "offset"
                              , Elm.record
                                    [ ( "hour", Elm.int 0 )
                                    , ( "minute", Elm.int 0 )
                                    ]
                              )
                            ]
                        )
                        |> Gen.Rfc3339.toString
                        |> Gen.Json.Encode.call_.string
                )

        Common.Date ->
            CliMonad.succeed
                (\date ->
                    date
                        |> Gen.Date.toIsoString
                        |> Gen.Json.Encode.call_.string
                )

        Common.Int _ ->
            CliMonad.succeed Gen.Json.Encode.call_.int

        Common.Float _ ->
            CliMonad.succeed Gen.Json.Encode.call_.float

        Common.Bool _ ->
            CliMonad.succeed Gen.Json.Encode.call_.bool

        Common.Null ->
            CliMonad.succeed (\_ -> Gen.Json.Encode.null)

        Common.Enum variants ->
            CliMonad.enumName variants
                |> CliMonad.andThen
                    (\maybeName ->
                        case maybeName of
                            Nothing ->
                                CliMonad.succeed Gen.Json.Encode.call_.string

                            Just name ->
                                CliMonad.map
                                    (\jsonNamespace rec ->
                                        Elm.apply
                                            (Elm.value
                                                { importFrom =
                                                    if qualify then
                                                        jsonNamespace

                                                    else
                                                        []
                                                , name = "encode" ++ Common.toTypeName name
                                                , annotation = Nothing
                                                }
                                            )
                                            [ rec ]
                                    )
                                    (CliMonad.moduleToNamespace Common.Json)
                    )

        Common.Object properties ->
            let
                allRequired : Bool
                allRequired =
                    List.all (\( _, { required } ) -> required) properties
            in
            properties
                |> CliMonad.combineMap
                    (\( key, field ) ->
                        typeToEncoder qualify field.type_
                            |> CliMonad.map
                                (\encoder rec ->
                                    let
                                        fieldExpr : Elm.Expression
                                        fieldExpr =
                                            Elm.get (Common.toValueName key) rec

                                        toTuple : Elm.Expression -> Elm.Expression
                                        toTuple value =
                                            Elm.tuple
                                                (Elm.string (Common.unwrapUnsafe key))
                                                (encoder value)
                                    in
                                    if allRequired then
                                        toTuple fieldExpr

                                    else if field.required then
                                        Gen.Maybe.make_.just (toTuple fieldExpr)

                                    else
                                        Gen.Maybe.map toTuple fieldExpr
                                )
                    )
                |> CliMonad.map
                    (\toProperties value ->
                        if allRequired then
                            Gen.Json.Encode.object <|
                                List.map (\prop -> prop value) toProperties

                        else
                            Gen.Json.Encode.call_.object <|
                                Gen.List.filterMap Gen.Basics.identity <|
                                    List.map (\prop -> prop value) toProperties
                    )

        Common.List t ->
            typeToEncoder qualify t
                |> CliMonad.map
                    (\encoder ->
                        Gen.Json.Encode.call_.list (Elm.functionReduced "rec" encoder)
                    )

        Common.Nullable t ->
            CliMonad.map
                (\encoder nullableValue ->
                    Elm.Case.custom
                        nullableValue
                        (Gen.OpenApi.Common.annotation_.nullable (Elm.Annotation.var "value"))
                        [ Elm.Case.branch0 "Null" Gen.Json.Encode.null
                        , Elm.Case.branch1 "Present"
                            ( "value", Elm.Annotation.var "value" )
                            encoder
                        ]
                )
                (typeToEncoder qualify t)

        Common.Value ->
            CliMonad.succeed <| Gen.Basics.identity

        Common.Ref ref ->
            CliMonad.map2
                (\jsonNamespace name rec ->
                    Elm.apply
                        (Elm.value
                            { importFrom =
                                if qualify then
                                    jsonNamespace

                                else
                                    []
                            , name = "encode" ++ Common.toTypeName name
                            , annotation = Nothing
                            }
                        )
                        [ rec ]
                )
                (CliMonad.moduleToNamespace Common.Json)
                (refToTypeName ref)

        Common.OneOf oneOfName oneOfData ->
            oneOfData
                |> CliMonad.combineMap
                    (\variant ->
                        CliMonad.map2
                            (\ann variantEncoder ->
                                Elm.Case.branch1 (toVariantName oneOfName variant.name)
                                    ( "content", ann )
                                    variantEncoder
                            )
                            (typeToAnnotationWithNullable True variant.type_)
                            (typeToEncoder qualify variant.type_)
                    )
                |> CliMonad.map2
                    (\typesNamespace branches rec ->
                        Elm.Case.custom rec
                            (Elm.Annotation.named typesNamespace oneOfName)
                            branches
                    )
                    (CliMonad.moduleToNamespace Common.Types)

        Common.Bytes ->
            CliMonad.todo "Encoder for bytes not implemented"
                |> CliMonad.map (\encoder _ -> encoder)

        Common.Unit ->
            CliMonad.succeed (\_ -> Gen.Json.Encode.null)


oneOfAnnotation : Bool -> Common.TypeName -> Common.OneOfData -> CliMonad Elm.Annotation.Annotation
oneOfAnnotation qualify oneOfName oneOfData =
    CliMonad.andThen
        (\typesNamespace ->
            Elm.Annotation.named
                (if qualify then
                    typesNamespace

                 else
                    []
                )
                oneOfName
                |> CliMonad.succeedWith
                    (FastDict.singleton oneOfName oneOfData)
        )
        (CliMonad.moduleToNamespace Common.Types)


refToTypeName : List String -> CliMonad Common.UnsafeName
refToTypeName ref =
    case ref of
        [ "#", "components", _, name ] ->
            CliMonad.succeed (Common.UnsafeName name)

        _ ->
            CliMonad.fail <| "Couldn't get the type ref (" ++ String.join "/" ref ++ ") for the response"


typeToDecoder : Bool -> Common.Type -> CliMonad Elm.Expression
typeToDecoder qualify type_ =
    let
        base : (a -> Elm.Expression) -> Maybe a -> Elm.Expression -> CliMonad Elm.Expression
        base toExpr const decoder =
            (case const of
                Nothing ->
                    decoder

                Just expected ->
                    decoder
                        |> Gen.Json.Decode.andThen
                            (\actual ->
                                Elm.ifThen
                                    (Elm.Op.equal actual (toExpr expected))
                                    (Gen.Json.Decode.succeed actual)
                                    (Gen.Json.Decode.call_.fail
                                        (Elm.Op.append
                                            (Elm.Op.append
                                                (Elm.Op.append
                                                    (Elm.string "Unexpected value: expected ")
                                                    (Gen.Json.Encode.encode 0 (toExpr expected))
                                                )
                                                (Elm.string " got ")
                                            )
                                            (Gen.Json.Encode.encode 0 actual)
                                        )
                                    )
                            )
            )
                |> CliMonad.succeed
    in
    case type_ of
        Common.Object properties ->
            List.foldl
                (\( key, field ) prevExprRes ->
                    CliMonad.map2
                        (\internalDecoder prevExpr ->
                            Elm.Op.pipe
                                (Elm.apply
                                    Gen.OpenApi.Common.values_.jsonDecodeAndMap
                                    [ if field.required then
                                        Gen.Json.Decode.field (Common.unwrapUnsafe key) internalDecoder

                                      else
                                        Gen.OpenApi.Common.decodeOptionalField
                                            (Common.unwrapUnsafe key)
                                            internalDecoder
                                    ]
                                )
                                prevExpr
                        )
                        (typeToDecoder qualify field.type_)
                        prevExprRes
                )
                (CliMonad.succeed
                    (Gen.Json.Decode.succeed
                        (Elm.function
                            (List.map (\( key, _ ) -> ( Common.toValueName key, Nothing )) properties)
                            (\args ->
                                Elm.record
                                    (List.map2
                                        (\( key, _ ) arg -> ( Common.toValueName key, arg ))
                                        properties
                                        args
                                    )
                            )
                        )
                    )
                )
                properties

        Common.String { const } ->
            base Elm.string const Gen.Json.Decode.string

        Common.DateTime ->
            CliMonad.succeed
                (Gen.Json.Decode.string
                    |> Gen.Json.Decode.andThen
                        (\raw ->
                            Gen.Result.caseOf_.result
                                (Gen.Parser.Advanced.call_.run Gen.Rfc3339.dateTimeOffsetParser raw)
                                { ok = \record -> Gen.Json.Decode.succeed (Elm.get "instant" record)

                                -- TODO: improve error message
                                , err = \_ -> Gen.Json.Decode.fail "Invalid RFC-3339 date-time"
                                }
                        )
                )

        Common.Date ->
            CliMonad.succeed
                (Gen.Json.Decode.string
                    |> Gen.Json.Decode.andThen
                        (\raw ->
                            Gen.Result.caseOf_.result
                                (Gen.Date.call_.fromIsoString raw)
                                { ok = Gen.Json.Decode.succeed
                                , err = Gen.Json.Decode.call_.fail
                                }
                        )
                )

        Common.Int { const } ->
            base Elm.int const Gen.Json.Decode.int

        Common.Float { const } ->
            base Elm.float const Gen.Json.Decode.float

        Common.Bool { const } ->
            base Elm.bool const Gen.Json.Decode.bool

        Common.Null ->
            CliMonad.succeed (Gen.Json.Decode.null Elm.unit)

        Common.Unit ->
            CliMonad.succeed (Gen.Json.Decode.succeed Elm.unit)

        Common.List t ->
            CliMonad.map Gen.Json.Decode.list
                (typeToDecoder qualify t)

        Common.Enum variants ->
            CliMonad.enumName variants
                |> CliMonad.andThen
                    (\maybeName ->
                        case maybeName of
                            Nothing ->
                                CliMonad.succeed Gen.Json.Decode.string

                            Just name ->
                                CliMonad.map
                                    (\jsonNamespace ->
                                        Elm.value
                                            { importFrom =
                                                if qualify then
                                                    jsonNamespace

                                                else
                                                    []
                                            , name = "decode" ++ Common.toTypeName name
                                            , annotation = Nothing
                                            }
                                    )
                                    (CliMonad.moduleToNamespace Common.Json)
                    )

        Common.Value ->
            CliMonad.succeed Gen.Json.Decode.value

        Common.Nullable t ->
            CliMonad.map
                (\decoder ->
                    Gen.Json.Decode.oneOf
                        [ Gen.Json.Decode.map
                            Gen.OpenApi.Common.make_.present
                            decoder
                        , Gen.Json.Decode.null
                            Gen.OpenApi.Common.make_.null
                        ]
                )
                (typeToDecoder qualify t)

        Common.Ref ref ->
            CliMonad.map2
                (\jsonNamespace name ->
                    Elm.value
                        { importFrom =
                            if qualify then
                                jsonNamespace

                            else
                                []
                        , name = "decode" ++ Common.toTypeName name
                        , annotation = Nothing
                        }
                )
                (CliMonad.moduleToNamespace Common.Json)
                (refToTypeName ref)

        Common.OneOf oneOfName variants ->
            variants
                |> CliMonad.combineMap
                    (\variant ->
                        typeToDecoder qualify variant.type_
                            |> CliMonad.map2
                                (\typesNamespace ->
                                    Gen.Json.Decode.call_.map
                                        (Elm.value
                                            { importFrom = typesNamespace
                                            , name = toVariantName oneOfName variant.name
                                            , annotation = Nothing
                                            }
                                        )
                                )
                                (CliMonad.moduleToNamespace Common.Types)
                    )
                |> CliMonad.map2
                    (\typesNamespace decoders ->
                        decoders
                            |> Gen.Json.Decode.oneOf
                            |> Elm.withType (Elm.Annotation.named typesNamespace oneOfName)
                    )
                    (CliMonad.moduleToNamespace Common.Types)

        Common.Bytes ->
            CliMonad.todo "Bytes decoder not implemented yet"


{-| Decode an optional field

    decodeString (decodeOptionalField "x" int) "{ \"x\": 3 }"
    --> Ok (Just 3)

    decodeString (decodeOptionalField "x" int) "{ \"x\": true }"
    --> Err ...

    decodeString (decodeOptionalField "x" int) "{ \"y\": 4 }"
    --> Ok Nothing

-}
decodeOptionalField :
    { declaration : Elm.Declaration
    , call : Elm.Expression -> Elm.Expression -> Elm.Expression
    , callFrom : List String -> Elm.Expression -> Elm.Expression -> Elm.Expression
    , value : List String -> Elm.Expression
    }
decodeOptionalField =
    let
        decoderAnnotation : Elm.Annotation.Annotation
        decoderAnnotation =
            Gen.Json.Decode.annotation_.decoder (Elm.Annotation.var "t")

        resultAnnotation : Elm.Annotation.Annotation
        resultAnnotation =
            Gen.Json.Decode.annotation_.decoder (Gen.Maybe.annotation_.maybe <| Elm.Annotation.var "t")
    in
    Elm.Declare.fn2 "decodeOptionalField"
        ( "key", Just Elm.Annotation.string )
        ( "fieldDecoder", Just decoderAnnotation )
    <|
        \key fieldDecoder ->
            -- The tricky part is that we want to make sure that
            -- if the field exists we error out if it has an incorrect shape.
            -- So what we do is we `oneOf` with `value` to avoid the `Nothing` branch,
            -- `andThen` we decode it. This is why we can't just use `maybe`, we would
            -- give `Nothing` when the shape is wrong.
            Gen.Json.Decode.oneOf
                [ Gen.Json.Decode.call_.map
                    (Elm.fn ( "_", Nothing ) <| \_ -> Elm.bool True)
                    (Gen.Json.Decode.call_.field key Gen.Json.Decode.value)
                , Gen.Json.Decode.succeed (Elm.bool False)
                ]
                |> Gen.Json.Decode.andThen
                    (\hasField ->
                        Elm.ifThen hasField
                            (Gen.Json.Decode.call_.field key
                                (Gen.Json.Decode.oneOf
                                    [ Gen.Json.Decode.map Gen.Maybe.make_.just fieldDecoder
                                    , Gen.Json.Decode.null Gen.Maybe.make_.nothing
                                    ]
                                )
                            )
                            (Gen.Json.Decode.succeed Gen.Maybe.make_.nothing)
                    )
                |> Elm.withType resultAnnotation


decodeOptionalFieldDocumentation : String
decodeOptionalFieldDocumentation =
    """Decode an optional field

    decodeString (decodeOptionalField "x" int) "{ "x": 3 }"
    --> Ok (Just 3)

    decodeString (decodeOptionalField "x" int) "{ "x": true }"
    --> Err ...

    decodeString (decodeOptionalField "x" int) "{ "y": 4 }"
    --> Ok Nothing"""
