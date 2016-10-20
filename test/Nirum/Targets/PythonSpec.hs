{-# LANGUAGE OverloadedLists, QuasiQuotes, ScopedTypeVariables #-}
{- |
This unit test module optionally depends on Python interpreter.
It internally tries to popen python3 executable, and import nirum Python
package.  If any of these prerequisites are not satisfied, tests depending
on Python interpreter are skipped instead of marked failed.

To make Python interpreter possible to import nirum package, you need to
install the nirum package to your Python site-packages using pip command.
We recommend to install the package inside a virtualenv (pyvenv) and
run this unit test in the virtualenv (pyvenv).  E.g.:

> $ pyvenv env
> $ . env/bin/activate
> (env)$ pip install git+git://github.com/spoqa/nirum-python.git
> (env)$ cabal test  # or: stack test
-}
module Nirum.Targets.PythonSpec where

import Control.Monad (forM_, void, unless)
import Data.Char (isSpace)
import Data.Maybe (fromJust, isJust)
import System.IO.Error (catchIOError)

import Data.Either (isRight)
import Data.List (dropWhileEnd)
import qualified Data.Map.Strict as M
import qualified Data.SemVer as SV
import qualified Data.Text as T
import qualified Data.Text.IO as TI
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (isValid, takeDirectory, (</>))
import System.Info (os)
import System.IO.Temp (withSystemTempDirectory)
import System.Process ( CreateProcess (cwd)
                      , proc
                      , readCreateProcess
                      , readCreateProcessWithExitCode
                      )
import Test.Hspec.Meta
import Text.Email.Validate (emailAddress)
import Text.InterpolatedString.Perl6 (q, qq)
import Text.Megaparsec (char, digitChar, runParser, some, space, string')
import Text.Megaparsec.String (Parser)

import Nirum.Constructs.Annotation (empty)
import Nirum.Constructs.DeclarationSet (DeclarationSet)
import Nirum.Constructs.Identifier (Identifier)
import Nirum.Constructs.Module (Module (Module))
import Nirum.Constructs.ModulePath (ModulePath, fromIdentifiers)
import Nirum.Constructs.Name (Name (Name))
import Nirum.Constructs.Service ( Method (Method)
                                , Parameter (Parameter)
                                , Service (Service)
                                )
import Nirum.Constructs.TypeDeclaration ( Field (Field)
                                        , EnumMember (EnumMember)
                                        , PrimitiveTypeIdentifier (..)
                                        , Tag (Tag)
                                        , Type ( Alias
                                               , EnumType
                                               , RecordType
                                               , UnboxedType
                                               , UnionType
                                               )
                                        , TypeDeclaration ( Import
                                                          , ServiceDeclaration
                                                          , TypeDeclaration
                                                          )
                                        )
import Nirum.Constructs.TypeExpression ( TypeExpression ( ListModifier
                                                        , MapModifier
                                                        , OptionModifier
                                                        , SetModifier
                                                        , TypeIdentifier
                                                        )
                                       )
import Nirum.Package (BoundModule (modulePath), Package, resolveBoundModule)
import Nirum.Package.Metadata ( Author (Author, email, name, uri)
                              , Metadata (Metadata, authors, version)
                              )
import Nirum.PackageSpec (createPackage)
import Nirum.Targets.Python ( Source (Source)
                            , Code
                            , CodeGen
                            , CodeGenContext ( localImports
                                             , standardImports
                                             , thirdPartyImports
                                             )
                            , CompileError
                            , InstallRequires ( InstallRequires
                                              , dependencies
                                              , optionalDependencies
                                              )
                            , addDependency
                            , addOptionalDependency
                            , compilePackage
                            , compilePrimitiveType
                            , compileTypeExpression
                            , emptyContext
                            , stringLiteral
                            , toAttributeName
                            , toClassName
                            , toImportPath
                            , toNamePair
                            , unionInstallRequires
                            , insertLocalImport
                            , insertStandardImport
                            , insertThirdPartyImports
                            , runCodeGen
                            )

codeGen :: a -> CodeGen a
codeGen = return

windows :: Bool
windows = os `elem` (["mingw32", "cygwin32", "win32"] :: [String])

data PyVersion = PyVersion Int Int Int deriving (Eq, Ord, Show)

installedPythonPaths :: Maybe FilePath -> IO [FilePath]
installedPythonPaths cwd' = do
    (exitCode, stdOut, _) <- readCreateProcessWithExitCode proc' ""
    return $ case exitCode of
        ExitSuccess -> filter isValid $ lines' stdOut
        _ -> []
  where
    proc' :: CreateProcess
    proc' = (if windows
             then proc "where.exe" ["python"]
             else proc "which" ["python3"]) { cwd = cwd' }
    lines' :: String -> [String]
    lines' = map T.unpack . filter (not . T.null)
                          . map T.strip
                          . T.lines
                          . T.pack

getPythonVersion :: Maybe FilePath -> FilePath -> IO (Maybe PyVersion)
getPythonVersion cwd' path' = do
    let proc' = (proc path' ["-V"]) { cwd = cwd' }
    pyVersionStr <- readCreateProcess proc' ""
    return $ case runParser pyVersionParser "<python3>" pyVersionStr of
            Left _ -> Nothing
            Right v -> Just v
  where
    pyVersionParser :: Parser PyVersion
    pyVersionParser = do
        void $ string' "python"
        space
        major <- integer
        void $ char '.'
        minor <- integer
        void $ char '.'
        micro <- integer
        return $ PyVersion major minor micro
    integer :: Parser Int
    integer = do
        digits <- some digitChar
        return (read digits :: Int)

findPython :: Maybe FilePath -> IO (Maybe FilePath)
findPython cwd' = installedPythonPaths cwd' >>= findPython'
  where
    findPython' :: [FilePath] -> IO (Maybe FilePath)
    findPython' (x : xs) = do
        pyVerM <- getPythonVersion cwd' x
        case pyVerM of
            Nothing -> findPython' xs
            Just version' -> if version' >= PyVersion 3 3 0
                             then return $ Just x
                             else findPython' xs
    findPython' [] = return Nothing

runPython' :: Maybe FilePath -> [String] -> String -> IO (Maybe String)
runPython' cwd' args stdinStr = do
    pyPathM <- findPython cwd'
    case pyPathM of
        Nothing -> do
            putStrLn "Python 3 seems not installed; skipping..."
            return Nothing
        Just path -> execute cwd' path args stdinStr
  where
    execute :: Maybe FilePath
            -> FilePath
            -> [String]
            -> String
            -> IO (Maybe String)
    execute cwdPath pyPath args' stdinStr' = do
        let proc' = (proc pyPath args') { cwd = cwdPath }
        result <- readCreateProcess proc' stdinStr'
        return $ Just result

runPython :: Maybe FilePath -> String -> IO (Maybe String)
runPython cwd' code' =
    catchIOError (runPython' cwd' [] code') $ \ e -> do
        putStrLn "\nThe following IO error was raised:\n"
        putStrLn $ indent "  " $ show e
        putStrLn "\n... while the following code was executed:\n"
        putStrLn $ indent "  " code'
        ioError e
  where
    indent :: String -> String -> String
    indent spaces content = unlines [spaces ++ l | l <- lines content]

testPythonSuit :: Maybe FilePath -> String -> T.Text -> IO ()
testPythonSuit cwd' suitCode testCode = do
    nirumPackageInstalledM <-
        runPython cwd' [q|
try: import nirum
except ImportError: print('F')
else: print('T')
            |]
    case nirumPackageInstalledM of
        Just nirumPackageInstalled ->
            case strip nirumPackageInstalled of
                "T" -> do
                    resultM <- runPython cwd' suitCode
                    case resultM of
                        Just result ->
                            unless (strip result == "True") $
                                expectationFailure $
                                T.unpack ("Test failed: " `T.append` testCode)
                        Nothing -> return ()
                _ -> putStrLn ("The nirum Python package cannot be " ++
                               "imported; skipped...")
        Nothing -> return ()
  where
    strip :: String -> String
    strip = dropWhile isSpace . dropWhileEnd isSpace

testPython :: Maybe FilePath -> T.Text -> T.Text -> IO ()
testPython cwd' defCode testCode = testPythonSuit cwd' code' testCode'
  where
    -- to workaround hlint's "Eta reduce" warning
    -- hlint seems unable to look inside qq string literal...
    testCode' :: T.Text
    testCode' = testCode
    code' :: String
    code' = [qq|$defCode

if __name__ == '__main__':
    print(bool($testCode'))
|]

testRaisePython :: Maybe FilePath -> T.Text -> T.Text -> T.Text -> IO ()
testRaisePython cwd' errorClassName defCode testCode =
    testPythonSuit cwd' code' testCode''
  where
    -- to workaround hlint's "Eta reduce" warning
    -- hlint seems unable to look inside qq string literal...
    testCode'' :: T.Text
    testCode'' = testCode
    code' :: String
    code' = [qq|$defCode

if __name__ == '__main__':
    try:
        $testCode''
    except $errorClassName:
        print(True)
    else:
        print(False)
|]

makeDummySource' :: [Identifier] -> Module -> Source
makeDummySource' pathPrefix m =
    Source pkg $ fromJust $ resolveBoundModule ["foo"] pkg
  where
    mp :: [Identifier] -> ModulePath
    mp identifiers = fromJust $ fromIdentifiers (pathPrefix ++ identifiers)
    metadata' :: Metadata
    metadata' = Metadata
        { version = SV.version 1 2 3 [] []
        , authors =
              [ Author
                    { name = "John Doe"
                    , email = Just (fromJust $ emailAddress "john@example.com")
                    , uri = Nothing
                    }
              ]
        }
    pkg :: Package
    pkg = createPackage
            metadata'
            [ (mp ["foo"], m)
            , ( mp ["foo", "bar"]
              , Module [ Import (mp ["qux"]) "path" empty
                       , TypeDeclaration "path-unbox" (UnboxedType "path") empty
                       , TypeDeclaration "int-unbox"
                                         (UnboxedType "bigint") empty
                       , TypeDeclaration "point"
                                         (RecordType [ Field "x" "int64" empty
                                                     , Field "y" "int64" empty
                                                     ])
                                         empty
                       ] Nothing
              )
            , ( mp ["qux"]
              , Module
                  [ TypeDeclaration "path" (Alias "text") empty
                  , TypeDeclaration "name" (UnboxedType "text") empty
                  ]
                  Nothing
              )
            ]

makeDummySource :: Module -> Source
makeDummySource = makeDummySource' []

run' :: CodeGen a -> (Either CompileError a, CodeGenContext)
run' c = runCodeGen c emptyContext

code :: CodeGen a -> a
code = either (const undefined) id . fst . run'

codeContext :: CodeGen a -> CodeGenContext
codeContext = snd . run'

compileError :: CodeGen a -> Maybe CompileError
compileError cg = either Just (const Nothing) $ fst $ runCodeGen cg emptyContext


spec :: Spec
spec = parallel $ do
    describe "CodeGen" $ do
        specify "packages and imports" $ do
            let c = do
                    insertStandardImport "sys"
                    insertThirdPartyImports
                        [("nirum", ["serialize_unboxed_type"])]
                    insertLocalImport ".." "Gender"
                    insertStandardImport "os"
                    insertThirdPartyImports [("nirum", ["serialize_enum_type"])]
                    insertLocalImport ".." "Path"
            let (e, ctx) = runCodeGen c emptyContext
            e `shouldSatisfy` isRight
            standardImports ctx `shouldBe` ["os", "sys"]
            thirdPartyImports ctx `shouldBe`
                [("nirum", ["serialize_unboxed_type", "serialize_enum_type"])]
            localImports ctx `shouldBe` [("..", ["Gender", "Path"])]
        specify "insertStandardImport" $ do
            let codeGen1 = insertStandardImport "sys"
            let (e1, ctx1) = runCodeGen codeGen1 emptyContext
            e1 `shouldSatisfy` isRight
            standardImports ctx1 `shouldBe` ["sys"]
            thirdPartyImports ctx1 `shouldBe` []
            localImports ctx1 `shouldBe` []
            compileError codeGen1 `shouldBe` Nothing
            let codeGen2 = codeGen1 >> insertStandardImport "os"
            let (e2, ctx2) = runCodeGen codeGen2 emptyContext
            e2 `shouldSatisfy` isRight
            standardImports ctx2 `shouldBe` ["os", "sys"]
            thirdPartyImports ctx2 `shouldBe` []
            localImports ctx2 `shouldBe` []
            compileError codeGen2 `shouldBe` Nothing

    specify "compilePrimitiveType" $ do
        code (compilePrimitiveType Bool) `shouldBe` "bool"
        code (compilePrimitiveType Bigint) `shouldBe` "int"
        let (decimalCode, decimalContext) = run' (compilePrimitiveType Decimal)
        decimalCode `shouldBe` Right "decimal.Decimal"
        standardImports decimalContext `shouldBe` ["decimal"]
        code (compilePrimitiveType Int32) `shouldBe` "int"
        code (compilePrimitiveType Int64) `shouldBe` "int"
        code (compilePrimitiveType Float32) `shouldBe` "float"
        code (compilePrimitiveType Float64) `shouldBe` "float"
        code (compilePrimitiveType Text) `shouldBe` "str"
        code (compilePrimitiveType Binary) `shouldBe` "bytes"
        let (dateCode, dateContext) = run' (compilePrimitiveType Date)
        dateCode `shouldBe` Right "datetime.date"
        standardImports dateContext `shouldBe` ["datetime"]
        let (datetimeCode, datetimeContext) =
                run' (compilePrimitiveType Datetime)
        datetimeCode `shouldBe` Right "datetime.datetime"
        standardImports datetimeContext `shouldBe` ["datetime"]
        let (uuidCode, uuidContext) = run' (compilePrimitiveType Uuid)
        uuidCode `shouldBe` Right "uuid.UUID"
        standardImports uuidContext `shouldBe` ["uuid"]
        code (compilePrimitiveType Uri) `shouldBe` "str"

    describe "compileTypeExpression" $ do
        let s = makeDummySource $ Module [] Nothing
        specify "TypeIdentifier" $ do
            let (c, ctx) = run' $
                    compileTypeExpression s (TypeIdentifier "bigint")
            standardImports ctx `shouldBe` []
            localImports ctx `shouldBe` []
            c `shouldBe` Right "int"
        specify "OptionModifier" $ do
            let (c', ctx') = run' $
                    compileTypeExpression s (OptionModifier "text")
            standardImports ctx' `shouldBe` ["typing"]
            localImports ctx' `shouldBe` []
            c' `shouldBe` Right "typing.Optional[str]"
        specify "SetModifier" $ do
            let (c'', ctx'') = run' $
                    compileTypeExpression s (SetModifier "text")
            standardImports ctx'' `shouldBe` ["typing"]
            localImports ctx'' `shouldBe` []
            c'' `shouldBe` Right "typing.AbstractSet[str]"
        specify "ListModifier" $ do
            let (c''', ctx''') = run' $
                    compileTypeExpression s (ListModifier "text")
            standardImports ctx''' `shouldBe` ["typing"]
            localImports ctx''' `shouldBe` []
            c''' `shouldBe` Right "typing.Sequence[str]"
        specify "MapModifier" $ do
            let (c'''', ctx'''') = run' $
                    compileTypeExpression s (MapModifier "uuid" "text")
            standardImports ctx'''' `shouldBe` ["uuid", "typing"]
            localImports ctx'''' `shouldBe` []
            c'''' `shouldBe` Right "typing.Mapping[uuid.UUID, str]"

    describe "toClassName" $ do
        it "transform the facial name of the argument into PascalCase" $ do
            toClassName "test" `shouldBe` "Test"
            toClassName "hello-world" `shouldBe` "HelloWorld"
        it "appends an underscore to the result if it's a reserved keyword" $ do
            toClassName "true" `shouldBe` "True_"
            toClassName "false" `shouldBe` "False_"
            toClassName "none" `shouldBe` "None_"

    describe "toAttributeName" $ do
        it "transform the facial name of the argument into snake_case" $ do
            toAttributeName "test" `shouldBe` "test"
            toAttributeName "hello-world" `shouldBe` "hello_world"
        it "appends an underscore to the result if it's a reserved keyword" $ do
            toAttributeName "def" `shouldBe` "def_"
            toAttributeName "lambda" `shouldBe` "lambda_"
            toAttributeName "nonlocal" `shouldBe` "nonlocal_"

    describe "toNamePair" $ do
        it "transforms the name to a Python code string of facial/behind pair" $
            do toNamePair "text" `shouldBe` "('text', 'text')"
               toNamePair (Name "test" "hello") `shouldBe` "('test', 'hello')"
        it "replaces hyphens to underscores" $ do
            toNamePair "hello-world" `shouldBe` "('hello_world', 'hello_world')"
            toNamePair (Name "hello-world" "annyeong-sesang") `shouldBe`
                "('hello_world', 'annyeong_sesang')"
        it "appends an underscore if the facial name is a Python keyword" $ do
            toNamePair "def" `shouldBe` "('def_', 'def')"
            toNamePair "lambda" `shouldBe` "('lambda_', 'lambda')"
            toNamePair (Name "abc" "lambda") `shouldBe` "('abc', 'lambda')"
            toNamePair (Name "lambda" "abc") `shouldBe` "('lambda_', 'abc')"

    specify "stringLiteral" $ do
        stringLiteral "asdf" `shouldBe` [q|"asdf"|]
        stringLiteral [q|Say 'hello world'|]
            `shouldBe` [q|"Say 'hello world'"|]
        stringLiteral [q|Say "hello world"|]
            `shouldBe` [q|"Say \"hello world\""|]
        stringLiteral "Say '\xc548\xb155'"
            `shouldBe` [q|u"Say '\uc548\ub155'"|]

    let test testRunner (Source pkg boundM) testCode =
            case errors of
                error' : _ -> fail $ T.unpack error'
                [] -> withSystemTempDirectory "nirumpy." $ \ dir -> do
                    forM_ codes $ \ (filePath, code') -> do
                        let filePath' = dir </> filePath
                            dirName = takeDirectory filePath'
                        createDirectoryIfMissing True dirName
                        TI.writeFile filePath' code'
                        {-- <- Remove '{' to print debug log
                        TI.putStrLn $ T.pack filePath'
                        TI.putStrLn code'
                        -- -}
                    testRunner (Just dir) defCode testCode
          where
            files :: M.Map FilePath (Either CompileError Code)
            files = compilePackage pkg
            errors :: [CompileError]
            errors = [error' | (_, Left error') <- M.toList files]
            codes :: [(FilePath, Code)]
            codes = [(path, code') | (path, Right code') <- M.toList files]
            pyImportPath :: T.Text
            pyImportPath = toImportPath $ modulePath boundM
            defCode :: Code
            defCode = [qq|from $pyImportPath import *|]
        tM = test testPython
        tT' typeDecls = tM $ makeDummySource $ Module typeDecls Nothing
        tT typeDecl = tT' [typeDecl]
        tR source excType = test (`testRaisePython` excType) source
        tR'' typeDecls = tR $ makeDummySource $ Module typeDecls Nothing
        tR' typeDecl = tR'' [typeDecl]

    describe "compilePackage" $ do
        it "returns a Map of file paths and their contents to generate" $ do
            let (Source pkg _) = makeDummySource $ Module [] Nothing
                files = compilePackage pkg
            M.keysSet files `shouldBe`
                [ "foo" </> "__init__.py"
                , "foo" </> "bar" </> "__init__.py"
                , "qux" </> "__init__.py"
                , "setup.py"
                ]
        it "creates an emtpy Python package directory if necessary" $ do
            let (Source pkg _) = makeDummySource' ["test"] $ Module [] Nothing
                files = compilePackage pkg
            M.keysSet files `shouldBe`
                [ "test" </> "__init__.py"
                , "test" </> "foo" </> "__init__.py"
                , "test" </> "foo" </> "bar" </> "__init__.py"
                , "test" </> "qux" </> "__init__.py"
                , "setup.py"
                ]
        specify "setup.py" $ do
            let setupPyFields = [ ("--name", "TestPackage")
                                , ("--author", "John Doe")
                                , ("--author-email", "john@example.com")
                                , ("--version", "1.2.3")
                                , ("--provides", "foo\nfoo.bar\nqux")
                                , ("--requires", "nirum")
                                ] :: [(String, T.Text)]
                source = makeDummySource $ Module [] Nothing
                testRunner cwd' _ _ =
                    {-- -- <- remove '{' to print debug log
                    do
                        let spath = case cwd' of
                                        Just c -> c </> "setup.py"
                                        Nothing -> "setup.py"
                        contents <- TI.readFile spath
                        TI.putStrLn "=========== setup.py ==========="
                        TI.putStrLn contents
                        TI.putStrLn "=========== /setup.py =========="
                    -- -}
                        forM_ setupPyFields $ \ (option, expected) -> do
                            out <- runPython' cwd' ["setup.py", option] ""
                            out `shouldSatisfy` isJust
                            let Just result = out
                            T.strip (T.pack result) `shouldBe` expected
            test testRunner source T.empty
        specify "unboxed type" $ do
            let decl = TypeDeclaration "float-unbox" (UnboxedType "float64")
                                       empty
            tT decl "isinstance(FloatUnbox, type)"
            tT decl "FloatUnbox(3.14).value == 3.14"
            tT decl "FloatUnbox(3.14) == FloatUnbox(3.14)"
            tT decl "FloatUnbox(3.14) != FloatUnbox(1.0)"
            tT decl [q|{FloatUnbox(3.14), FloatUnbox(3.14), FloatUnbox(1.0)} ==
                       {FloatUnbox(3.14), FloatUnbox(1.0)}|]
            tT decl "FloatUnbox(3.14).__nirum_serialize__() == 3.14"
            tT decl "FloatUnbox.__nirum_deserialize__(3.14) == FloatUnbox(3.14)"
            tT decl "FloatUnbox.__nirum_deserialize__(3.14) == FloatUnbox(3.14)"
            tT decl "hash(FloatUnbox(3.14))"
            tT decl "hash(FloatUnbox(3.14)) != 3.14"
            -- FIXME: Is TypeError/ValueError is appropriate exception type
            -- for deserialization error?  For such case, json.loads() raises
            -- JSONDecodeError (which inherits ValueError).
            tR' decl "(TypeError, ValueError)"
                     "FloatUnbox.__nirum_deserialize__('a')"
            tR' decl "TypeError" "FloatUnbox('a')"
            let decls = [ Import ["foo", "bar"] "path-unbox" empty
                        , TypeDeclaration "imported-type-unbox"
                                          (UnboxedType "path-unbox") empty
                        ]
            tT' decls "isinstance(ImportedTypeUnbox, type)"
            tT' decls [q|
                ImportedTypeUnbox(PathUnbox('/path/string')).value.value ==
                '/path/string'
            |]
            tT' decls [q|ImportedTypeUnbox(PathUnbox('/path/string')) ==
                         ImportedTypeUnbox(PathUnbox('/path/string'))|]
            tT' decls [q|ImportedTypeUnbox(PathUnbox('/path/string')) !=
                         ImportedTypeUnbox(PathUnbox('/other/path'))|]
            tT' decls [q|{ImportedTypeUnbox(PathUnbox('/path/string')),
                          ImportedTypeUnbox(PathUnbox('/path/string')),
                          ImportedTypeUnbox(PathUnbox('/other/path')),
                          ImportedTypeUnbox(PathUnbox('/path/string')),
                          ImportedTypeUnbox(PathUnbox('/other/path'))} ==
                         {ImportedTypeUnbox(PathUnbox('/path/string')),
                          ImportedTypeUnbox(PathUnbox('/other/path'))}|]
            tT' decls [q|
                ImportedTypeUnbox(PathUnbox('/path/string')
                    ).__nirum_serialize__() == '/path/string'
            |]
            tT' decls [q|
                ImportedTypeUnbox.__nirum_deserialize__('/path/string') ==
                ImportedTypeUnbox(PathUnbox('/path/string'))
            |]
            -- FIXME: Is TypeError/ValueError is appropriate exception type
            -- for deserialization error?  For such case, json.loads() raises
            -- JSONDecodeError (which inherits ValueError).
            tR'' decls "(TypeError, ValueError)"
                       "ImportedTypeUnbox.__nirum_deserialize__(123)"
            tR'' decls "TypeError" "ImportedTypeUnbox(123)"
            let boxedAlias = [ Import ["qux"] "path" empty
                             , TypeDeclaration "way"
                                               (UnboxedType "path") empty
                             ]
            tT' boxedAlias "Way('.').value == '.'"
            tT' boxedAlias "Way(Path('.')).value == '.'"
            tT' boxedAlias "Way.__nirum_deserialize__('.') == Way('.')"
            tT' boxedAlias "Way('.').__nirum_serialize__() == '.'"
            let aliasUnboxed = [ Import ["qux"] "name" empty
                               , TypeDeclaration "irum" (Alias "name") empty
                               ]
            tT' aliasUnboxed "Name('khj') == Irum('khj')"
            tT' aliasUnboxed "Irum.__nirum_deserialize__('khj') == Irum('khj')"
            tT' aliasUnboxed "Irum('khj').__nirum_serialize__() == 'khj'"
            tT' aliasUnboxed "Irum.__nirum_deserialize__('khj') == Name('khj')"
            tT' aliasUnboxed "Irum.__nirum_deserialize__('khj') == Irum('khj')"
        specify "enum type" $ do
            let members = [ "male"
                          , EnumMember (Name "female" "yeoseong") empty
                          ] :: DeclarationSet EnumMember
                decl = TypeDeclaration "gender" (EnumType members) empty
            tT decl "type(Gender) is enum.EnumMeta"
            tT decl "set(Gender) == {Gender.male, Gender.female}"
            tT decl "Gender.male.value == 'male'"
            tT decl "Gender.female.value == 'yeoseong'"
            tT decl "Gender.__nirum_deserialize__('male') == Gender.male"
            tT decl "Gender.__nirum_deserialize__('yeoseong') == Gender.female"
            tR' decl "ValueError" "Gender.__nirum_deserialize__('namja')"
            tT decl "Gender.male.__nirum_serialize__() == 'male'"
            tT decl "Gender.female.__nirum_serialize__() == 'yeoseong'"
            let members' = [ "soryu-asuka-langley"
                           , "ayanami-rei"
                           , "ikari-shinji"
                           , "katsuragi-misato"
                           , "nagisa-kaworu"
                           ] :: DeclarationSet EnumMember
                decl' = TypeDeclaration "eva-char" (EnumType members') empty
            tT decl' "type(EvaChar) is enum.EnumMeta"
            tT decl' [q|
                set(EvaChar) == {EvaChar.soryu_asuka_langley,
                                 EvaChar.ayanami_rei,
                                 EvaChar.ikari_shinji,
                                 EvaChar.katsuragi_misato,
                                 EvaChar.nagisa_kaworu}
            |]
            tT decl' "EvaChar.soryu_asuka_langley.value=='soryu_asuka_langley'"
            tT decl' [q|EvaChar.soryu_asuka_langley.__nirum_serialize__() ==
                        'soryu_asuka_langley'|]
            tT decl' [q|EvaChar.__nirum_deserialize__('soryu_asuka_langley') ==
                        EvaChar.soryu_asuka_langley|]
            tT decl' [q|EvaChar.__nirum_deserialize__('soryu-asuka-langley') ==
                        EvaChar.soryu_asuka_langley|]  -- to be robust
        specify "record type" $ do
            let fields = [ Field (Name "left" "x") "bigint" empty
                         , Field "top" "bigint" empty
                         ]
                payload = "{'_type': 'point', 'x': 3, 'top': 14}" :: T.Text
                decl = TypeDeclaration "point" (RecordType fields) empty
            tT decl "isinstance(Point, type)"
            tT decl "Point(left=3, top=14).left == 3"
            tT decl "Point(left=3, top=14).top == 14"
            tT decl "Point(left=3, top=14) == Point(left=3, top=14)"
            tT decl "Point(left=3, top=14) != Point(left=3, top=15)"
            tT decl "Point(left=3, top=14) != Point(left=4, top=14)"
            tT decl "Point(left=3, top=14) != Point(left=4, top=15)"
            tT decl "Point(left=3, top=14) != 'foo'"
            tT decl "hash(Point(left=3, top=14))"
            tT decl [q|Point(left=3, top=14).__nirum_serialize__() ==
                       {'_type': 'point', 'x': 3, 'top': 14}|]
            tT decl [qq|Point.__nirum_deserialize__($payload) ==
                        Point(left=3, top=14)|]
            tR' decl "ValueError"
                "Point.__nirum_deserialize__({'x': 3, 'top': 14})"
            tR' decl "ValueError"
                "Point.__nirum_deserialize__({'_type': 'foo'})"
            tR' decl "TypeError" "Point(left=1, top='a')"
            tR' decl "TypeError" "Point(left='a', top=1)"
            tR' decl "TypeError" "Point(left='a', top='b')"
            let fields' = [ Field "left" "int-unbox" empty
                          , Field "top" "int-unbox" empty
                          ]
                decls = [ Import ["foo", "bar"] "int-unbox" empty
                        , TypeDeclaration "point" (RecordType fields') empty
                        ]
                payload' = "{'_type': 'point', 'left': 3, 'top': 14}" :: T.Text
            tT' decls "isinstance(Point, type)"
            tT' decls [q|Point(left=IntUnbox(3), top=IntUnbox(14)).left ==
                         IntUnbox(3)|]
            tT' decls [q|Point(left=IntUnbox(3), top=IntUnbox(14)).top ==
                         IntUnbox(14)|]
            tT' decls [q|Point(left=IntUnbox(3), top=IntUnbox(14)) ==
                         Point(left=IntUnbox(3), top=IntUnbox(14))|]
            tT' decls [q|Point(left=IntUnbox(3), top=IntUnbox(14)) !=
                         Point(left=IntUnbox(3), top=IntUnbox(15))|]
            tT' decls [q|Point(left=IntUnbox(3), top=IntUnbox(14)) !=
                         Point(left=IntUnbox(4), top=IntUnbox(14))|]
            tT' decls [q|Point(left=IntUnbox(3), top=IntUnbox(14)) !=
                         Point(left=IntUnbox(4), top=IntUnbox(15))|]
            tT' decls "Point(left=IntUnbox(3), top=IntUnbox(14)) != 'foo'"
            tT' decls [q|Point(left=IntUnbox(3),
                               top=IntUnbox(14)).__nirum_serialize__() ==
                         {'_type': 'point', 'left': 3, 'top': 14}|]
            tT' decls [qq|Point.__nirum_deserialize__($payload') ==
                          Point(left=IntUnbox(3), top=IntUnbox(14))|]
            tR'' decls "ValueError"
                 "Point.__nirum_deserialize__({'left': 3, 'top': 14})"
            tR'' decls "ValueError"
                 "Point.__nirum_deserialize__({'_type': 'foo'})"
            tR'' decls "TypeError" "Point(left=IntUnbox(1), top='a')"
            tR'' decls "TypeError" "Point(left=IntUnbox(1), top=2)"
            let fields'' = [ Field "xy" "point" empty
                           , Field "z" "int64" empty
                           ]
                decls' = [ Import ["foo", "bar"] "point" empty
                         , TypeDeclaration "point3d"
                                           (RecordType fields'')
                                           empty
                         ]
            tT' decls' "isinstance(Point3d, type)"
            tT' decls' [q|Point3d(xy=Point(x=1, y=2), z=3).xy ==
                          Point(x=1, y=2)|]
            tT' decls' "Point3d(xy=Point(x=1, y=2), z=3).xy.x == 1"
            tT' decls' "Point3d(xy=Point(x=1, y=2), z=3).xy.y == 2"
            tT' decls' "Point3d(xy=Point(x=1, y=2), z=3).z == 3"
            tT' decls' [q|Point3d(xy=Point(x=1, y=2), z=3).__nirum_serialize__()
                          == {'_type': 'point3d',
                              'xy': {'_type': 'point', 'x': 1, 'y': 2},
                              'z': 3}|]
            tT' decls' [q|Point3d.__nirum_deserialize__({
                              '_type': 'point3d',
                              'xy': {'_type': 'point', 'x': 1, 'y': 2},
                              'z': 3
                          }) == Point3d(xy=Point(x=1, y=2), z=3)|]
        specify "record type with one field" $ do
            let fields = [ Field "length" "bigint" empty ]
                payload = "{'_type': 'line', 'length': 3}" :: T.Text
                decl = TypeDeclaration "line" (RecordType fields) empty
            tT decl "isinstance(Line, type)"
            tT decl "Line(length=10).length == 10"
            tT decl "Line.__slots__ == ('length', )"
            tT decl [qq|Line(length=3).__nirum_serialize__() == $payload|]
        specify "union type" $ do
            let westernNameTag =
                    Tag "western-name" [ Field "first-name" "text" empty
                                       , Field "middle-name" "text" empty
                                       , Field "last-name" "text" empty
                                       ] empty
                eastAsianNameTag =
                    Tag "east-asian-name" [ Field "family-name" "text" empty
                                          , Field "given-name" "text" empty
                                          ] empty
                cultureAgnosticNameTag =
                    Tag "culture-agnostic-name"
                        [ Field "fullname" "text" empty ]
                        empty
                tags = [ westernNameTag
                       , eastAsianNameTag
                       , cultureAgnosticNameTag
                       ]
                decl = TypeDeclaration "name" (UnionType tags) empty
            tT decl "isinstance(Name, type)"
            tT decl "Name.Tag.western_name.value == 'western_name'"
            tT decl "Name.Tag.east_asian_name.value == 'east_asian_name'"
            tT decl [q|Name.Tag.culture_agnostic_name.value ==
                       'culture_agnostic_name'|]
            tT decl "isinstance(WesternName, type)"
            tT decl "issubclass(WesternName, Name)"
            tR' decl "NotImplementedError" "Name()"
            tT decl [q|WesternName(first_name='foo', middle_name='bar',
                                   last_name='baz').first_name == 'foo'|]
            tT decl [q|WesternName(first_name='foo', middle_name='bar',
                                   last_name='baz').middle_name == 'bar'|]
            tT decl [q|WesternName(first_name='foo', middle_name='bar',
                                   last_name='baz').last_name == 'baz'|]
            tR' decl "TypeError" [q|WesternName(first_name=1,middle_name='bar',
                                                last_name='baz')|]
            tR' decl "TypeError" [q|WesternName(first_name='foo',
                                                middle_name=1,
                                                last_name='baz')|]
            tR' decl "TypeError" [q|WesternName(first_name='foo',
                                                middle_name='bar',
                                                last_name=1)|]
            tT decl [q|WesternName(first_name='foo', middle_name='bar',
                                   last_name='baz') ==
                       WesternName(first_name='foo', middle_name='bar',
                                   last_name='baz')
                    |]
            tT decl [q|WesternName(first_name='wrong',
                                   middle_name='bar', last_name='baz') !=
                       WesternName(first_name='foo', middle_name='bar',
                                   last_name='baz')
                    |]
            tT decl [q|WesternName(first_name='foo', middle_name='wrong',
                                    last_name='baz') !=
                       WesternName(first_name='foo', middle_name='bar',
                                   last_name='baz')
                    |]
            tT decl [q|WesternName(first_name='foo', middle_name='bar',
                                   last_name='wrong') !=
                       WesternName(first_name='foo', middle_name='bar',
                                   last_name='baz')
                    |]
            tT decl [q|WesternName(first_name='wrong', middle_name='wrong',
                                   last_name='wrong') !=
                       WesternName(first_name='foo', middle_name='bar',
                                   last_name='baz')|]
            tT decl [q|hash(WesternName(first_name='foo', middle_name='bar',
                                        last_name='baz'))|]
            tT decl "isinstance(EastAsianName, type)"
            tT decl "issubclass(EastAsianName, Name)"
            tT decl [q|EastAsianName(family_name='foo',
                                     given_name='baz').family_name == 'foo'|]
            tT decl [q|EastAsianName(family_name='foo',
                                     given_name='baz').given_name == 'baz'|]
            tT decl [q|EastAsianName(family_name='foo', given_name='baz') ==
                       EastAsianName(family_name='foo', given_name='baz')|]
            tT decl [q|EastAsianName(family_name='foo',
                                     given_name='wrong') !=
                       EastAsianName(family_name='foo', given_name='baz')|]
            tT decl [q|EastAsianName(family_name='wrong', given_name='baz') !=
                       EastAsianName(family_name='foo', given_name='baz')|]
            tT decl [q|EastAsianName(family_name='wrong',
                                     given_name='wrong') !=
                       EastAsianName(family_name='foo', given_name='baz')|]
            tR'
                decl
                "TypeError"
                "EastAsianName(family_name=1, given_name='baz')"
            tR'
                decl
                "TypeError"
                "EastAsianName(family_name='foo', given_name=2)"
            tT decl "isinstance(CultureAgnosticName, type)"
            tT decl "issubclass(CultureAgnosticName, Name)"
            tT
                decl
                "CultureAgnosticName(fullname='foobar').fullname == 'foobar'"
            tT decl [q|CultureAgnosticName(fullname='foobar') ==
                       CultureAgnosticName(fullname='foobar')|]
            tT decl [q|CultureAgnosticName(fullname='wrong') !=
                       CultureAgnosticName(fullname='foobar')|]
            tR' decl "TypeError" "CultureAgnosticName(fullname=1)"
        specify "union type with one tag" $ do
            let cultureAgnosticNameTag =
                    Tag "pop"
                        [ Field "country" "text" empty ]
                        empty
                tags = [cultureAgnosticNameTag]
                decl = TypeDeclaration "music" (UnionType tags) empty
            tT decl "Pop(country='KR').country == 'KR'"
            tT decl "Pop(country='KR') == Pop(country='KR')"
            tT decl "Pop(country='US') != Pop(country='KR')"
            tR' decl "TypeError" "Pop(country=1)"
            tT decl "Pop.__slots__ == ('country', )"
        specify "union type with behind names" $ do
            let pop =
                    Tag (Name "pop" "popular_music")
                        [ Field "country" "text" empty ]
                        empty
                tags = [pop]
                decl = TypeDeclaration "music" (UnionType tags) empty
            tT decl "Pop(country='KR').__nirum_tag__.value == 'popular_music'"
        specify "union type with tag has no field" $ do
            let decl = TypeDeclaration
                    "status"
                    (UnionType [Tag "run" [] empty, Tag "stop" [] empty])
                    empty
            tT decl "Run().__nirum_tag__.value == 'run'"
            tT decl "Stop().__nirum_tag__.value == 'stop'"
        specify "service" $ do
            let null' = ServiceDeclaration "null-service" (Service []) empty
                pingService = Service [Method "ping"
                                              [Parameter "nonce" "text" empty]
                                              "bool"
                                              Nothing
                                              empty]
                ping' = ServiceDeclaration "ping-service" pingService empty
            tT null' "issubclass(NullService, __import__('nirum').rpc.Service)"
            tT ping' "issubclass(PingService, __import__('nirum').rpc.Service)"
            tT ping' [q|set(PingService.ping.__annotations__) ==
                            {'nonce', 'return'}|]
            tT ping' "PingService.ping.__annotations__['nonce'] is str"
            tT ping' "PingService.ping.__annotations__['return'] is bool"
            tR' ping' "NotImplementedError" "PingService().ping('nonce')"
            tR' ping' "NotImplementedError" "PingService().ping(nonce='nonce')"
            tR' ping' "TypeError" "PingService().ping(wrongkwd='a')"

    describe "InstallRequires" $ do
        let req = InstallRequires [] []
            req2 = req { dependencies = ["six"] }
            req3 = req { optionalDependencies = [((3, 4), ["enum34"])] }
        specify "addDependency" $ do
            addDependency req "six" `shouldBe` req2
            addDependency req2 "six" `shouldBe` req2
            addDependency req "nirum" `shouldBe`
                req { dependencies = ["nirum"] }
            addDependency req2 "nirum" `shouldBe`
                req2 { dependencies = ["nirum", "six"] }
        specify "addOptionalDependency" $ do
            addOptionalDependency req (3, 4) "enum34" `shouldBe` req3
            addOptionalDependency req3 (3, 4) "enum34" `shouldBe` req3
            addOptionalDependency req (3, 4) "ipaddress" `shouldBe`
                req { optionalDependencies = [((3, 4), ["ipaddress"])] }
            addOptionalDependency req3 (3, 4) "ipaddress" `shouldBe`
                req { optionalDependencies = [ ((3, 4), ["enum34", "ipaddress"])
                                             ]
                    }
            addOptionalDependency req (3, 5) "typing" `shouldBe`
                req { optionalDependencies = [((3, 5), ["typing"])] }
            addOptionalDependency req3 (3, 5) "typing" `shouldBe`
                req3 { optionalDependencies = [ ((3, 4), ["enum34"])
                                              , ((3, 5), ["typing"])
                                              ]
                     }
        specify "unionInstallRequires" $ do
            (req `unionInstallRequires` req) `shouldBe` req
            (req `unionInstallRequires` req2) `shouldBe` req2
            (req2 `unionInstallRequires` req) `shouldBe` req2
            (req `unionInstallRequires` req3) `shouldBe` req3
            (req3 `unionInstallRequires` req) `shouldBe` req3
            let req4 = req3 { dependencies = ["six"] }
            (req2 `unionInstallRequires` req3) `shouldBe` req4
            (req3 `unionInstallRequires` req2) `shouldBe` req4
            let req5 = req { dependencies = ["nirum"]
                           , optionalDependencies = [((3, 4), ["ipaddress"])]
                           }
                req6 = addOptionalDependency (addDependency req4 "nirum")
                                             (3, 4) "ipaddress"
            (req4 `unionInstallRequires` req5) `shouldBe` req6
            (req5 `unionInstallRequires` req4) `shouldBe` req6

{-# ANN module ("HLint: ignore Functor law" :: String) #-}
{-# ANN module ("HLint: ignore Monad law, left identity" :: String) #-}
{-# ANN module ("HLint: ignore Monad law, right identity" :: String) #-}
{-# ANN module ("HLint: ignore Use >=>" :: String) #-}
