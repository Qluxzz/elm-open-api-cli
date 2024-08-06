module JsonSchema.Generate exposing (schemaToDeclarations)

import CliMonad exposing (CliMonad)
import Common
import Elm
import Elm.Annotation
import Elm.Case
import Elm.Op
import Elm.ToString
import Gen.Json.Decode
import Gen.Json.Encode
import Gen.Maybe
import Json.Schema.Definitions
import SchemaUtils
import String.Extra


schemaToDeclarations : String -> Json.Schema.Definitions.Schema -> CliMonad (List ( Common.Module, Elm.Declaration ))
schemaToDeclarations name schema =
    SchemaUtils.schemaToType False schema
        |> CliMonad.andThen
            (\{ type_, documentation } ->
                case type_ of
                    Common.Enum enumVariants ->
                        [ ( Common.Types
                          , enumVariants
                                |> List.map (\variantName -> Elm.variant (SchemaUtils.toVariantName name variantName))
                                |> Elm.customType name
                                |> (case documentation of
                                        Nothing ->
                                            identity

                                        Just doc ->
                                            Elm.withDocumentation doc
                                   )
                                |> Elm.exposeWith
                                    { exposeConstructor = True
                                    , group = Just "Enum"
                                    }
                          )
                            |> CliMonad.succeed
                        , ( Common.Types
                          , Elm.fn ( "value", Just (Elm.Annotation.named [] name) )
                                (\value ->
                                    enumVariants
                                        |> List.map
                                            (\variant ->
                                                Elm.Case.branch0
                                                    (SchemaUtils.toVariantName name variant)
                                                    (Elm.string variant)
                                            )
                                        |> Elm.Case.custom value (Elm.Annotation.named [] name)
                                )
                                |> Elm.declaration (name ++ "ToString")
                                |> Elm.exposeWith
                                    { exposeConstructor = False
                                    , group = Just "Enum"
                                    }
                          )
                            |> CliMonad.succeed
                        , ( Common.Types
                          , Elm.fn ( "value", Just Elm.Annotation.string )
                                (\value ->
                                    Elm.Case.string value
                                        { cases =
                                            enumVariants
                                                |> List.map
                                                    (\variant ->
                                                        ( SchemaUtils.toVariantName name variant
                                                        , Gen.Maybe.make_.just (Elm.val (SchemaUtils.toVariantName name variant))
                                                        )
                                                    )
                                        , otherwise = Gen.Maybe.make_.nothing
                                        }
                                )
                                |> Elm.declaration (name ++ "FromString")
                                |> Elm.exposeWith
                                    { exposeConstructor = False
                                    , group = Just "Enum"
                                    }
                          )
                            |> CliMonad.succeed
                        , CliMonad.map
                            (\typesNamespace ->
                                ( Common.Json
                                , Elm.declaration
                                    ("decode" ++ name)
                                    (Gen.Json.Decode.string
                                        |> Gen.Json.Decode.andThen
                                            (\str ->
                                                Gen.Maybe.caseOf_.maybe
                                                    (Elm.apply
                                                        (Elm.value
                                                            { importFrom = typesNamespace
                                                            , name = String.Extra.decapitalize name ++ "FromString"
                                                            , annotation = Nothing
                                                            }
                                                        )
                                                        [ str ]
                                                    )
                                                    { just = Gen.Json.Decode.succeed
                                                    , nothing =
                                                        Gen.Json.Decode.call_.fail
                                                            (Elm.Op.append
                                                                str
                                                                (Elm.string (" is not a valid " ++ name))
                                                            )
                                                    }
                                            )
                                        |> Elm.withType (Gen.Json.Decode.annotation_.decoder (Elm.Annotation.named typesNamespace name))
                                    )
                                    |> Elm.exposeWith
                                        { exposeConstructor = False
                                        , group = Just "Decoders"
                                        }
                                )
                            )
                            (CliMonad.moduleToNamespace Common.Types)
                        , CliMonad.map
                            (\typesNamespace ->
                                ( Common.Json
                                , Elm.declaration ("encode" ++ name)
                                    (Elm.functionReduced "rec"
                                        (\value ->
                                            Elm.apply
                                                (Elm.value
                                                    { importFrom = typesNamespace
                                                    , name = String.Extra.decapitalize name ++ "ToString"
                                                    , annotation = Nothing
                                                    }
                                                )
                                                [ value ]
                                                |> Gen.Json.Encode.call_.string
                                        )
                                        |> Elm.withType (Elm.Annotation.function [ Elm.Annotation.named typesNamespace name ] Gen.Json.Encode.annotation_.value)
                                    )
                                    |> Elm.exposeWith
                                        { exposeConstructor = False
                                        , group = Just "Encoders"
                                        }
                                )
                            )
                            (CliMonad.moduleToNamespace Common.Types)
                        ]
                            |> CliMonad.combine

                    _ ->
                        type_
                            |> SchemaUtils.typeToAnnotation False
                            |> CliMonad.andThen
                                (\annotation ->
                                    let
                                        typeName : Common.TypeName
                                        typeName =
                                            Common.typifyName name
                                    in
                                    if (Elm.ToString.annotation annotation).signature == typeName then
                                        CliMonad.succeed []

                                    else
                                        [ ( Common.Types
                                          , Elm.alias typeName annotation
                                                |> (case documentation of
                                                        Nothing ->
                                                            identity

                                                        Just doc ->
                                                            Elm.withDocumentation doc
                                                   )
                                                |> Elm.exposeWith
                                                    { exposeConstructor = False
                                                    , group = Just "Aliases"
                                                    }
                                          )
                                            |> CliMonad.succeed
                                        , CliMonad.map2
                                            (\namespace schemaDecoder ->
                                                ( Common.Json
                                                , Elm.declaration
                                                    ("decode" ++ typeName)
                                                    (schemaDecoder
                                                        |> Elm.withType (Gen.Json.Decode.annotation_.decoder (Elm.Annotation.named (Common.moduleToNamespace namespace Common.Types) typeName))
                                                    )
                                                    |> Elm.exposeWith
                                                        { exposeConstructor = False
                                                        , group = Just "Decoders"
                                                        }
                                                )
                                            )
                                            CliMonad.namespace
                                            (schemaToDecoder False schema)
                                        , CliMonad.map2
                                            (\namespace encoder ->
                                                ( Common.Json
                                                , Elm.declaration ("encode" ++ typeName)
                                                    (Elm.functionReduced "rec" encoder
                                                        |> Elm.withType (Elm.Annotation.function [ Elm.Annotation.named (Common.moduleToNamespace namespace Common.Types) typeName ] Gen.Json.Encode.annotation_.value)
                                                    )
                                                    |> Elm.exposeWith
                                                        { exposeConstructor = False
                                                        , group = Just "Encoders"
                                                        }
                                                )
                                            )
                                            CliMonad.namespace
                                            (schemaToEncoder False schema)
                                        ]
                                            |> CliMonad.combine
                                )
            )
        |> CliMonad.withPath name


schemaToDecoder : Bool -> Json.Schema.Definitions.Schema -> CliMonad Elm.Expression
schemaToDecoder qualify schema =
    SchemaUtils.schemaToType True schema
        |> CliMonad.andThen (\{ type_ } -> SchemaUtils.typeToDecoder qualify type_)


schemaToEncoder : Bool -> Json.Schema.Definitions.Schema -> CliMonad (Elm.Expression -> Elm.Expression)
schemaToEncoder qualify schema =
    SchemaUtils.schemaToType True schema
        |> CliMonad.andThen (\{ type_ } -> SchemaUtils.typeToEncoder qualify type_)
