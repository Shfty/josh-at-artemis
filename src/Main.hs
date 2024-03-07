{-# LANGUAGE OverloadedStrings #-}

import Data.FileTree

import qualified Data.Tree as T

import Hakyll
import Hakyll.Breadcrumb
import Hakyll.Compiler.Overridable
import Hakyll.Highlighting
import Hakyll.Layout
import Hakyll.Sass
import Hakyll.Wallpaper

import Control.Monad
import Data.Function
import Data.Text (splitOn, strip)
import Data.Tuple
import System.FilePath
import Text.Blaze.Html.Renderer.String
import Text.Pandoc.Highlighting

import qualified Data.Aeson as JSON
import qualified Data.ByteString.Lazy as ByteString
import qualified Data.Map
import Data.Maybe
import Hakyll.Commands (watch)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Data.Aeson.Types (parseMaybe)
import Data.Aeson ((.:))

--------------------------------------------------------------------------------
-- Constants

configPattern = "config"

imagesPattern = "images/*"

landscapeWallpaperPattern = "images/base.png" :: Pattern
portraitWallpaperPattern = "images/base-vertical.png" :: Pattern
wallpaperPattern = landscapeWallpaperPattern .||. portraitWallpaperPattern
notWallpaperPattern = complement wallpaperPattern

imagePattern = imagesPattern .&&. notWallpaperPattern

staticAssetPattern =
    imagePattern
        .||. "images/**.png"
        .||. "images/**.jpeg"
        .||. "images/**.gif"
        .||. "images/**.mkv"
        .||. "fonts/**.woff"
        .||. "fonts/**.woff2"

pageAssetPattern =
    "pages/**.png"
        .||. "pages/**.jpg"
        .||. "pages/**.gif"
        .||. "pages/**.mkv"

metadataPattern = "**.metadata"
imageAssetPattern = "**.png" .||. "**.jpg" .||. "**.gif"
videoAssetPattern = "**.mkv" .||. "**.mp4"

assetPattern = metadataPattern .||. imageAssetPattern .||. videoAssetPattern
notAssetPattern = complement assetPattern

recursivePattern = "pages/**" .&&. notAssetPattern
indexPattern = "**index.*"
notIndexPattern = complement indexPattern
recursiveCategoriesPattern = recursivePattern .&&. indexPattern
recursivePagesPattern = recursivePattern .&&. notIndexPattern

templatePattern = "templates/**.html"

documentTemplate = "templates/document.html"
footerTemplate = "templates/footer.html"
headerTemplate = "templates/content/header.html"
slugTemplate = "templates/slug.html"
flexColumnTemplate = "templates/flex-column.html"
flexRowTemplate = "templates/flex-row.html"
flexScrollTemplate = "templates/flex-scroll.html"

postTemplate = "templates/post.html"
categoryTemplate = "templates/category.html"

cssTemplate = "css/main.scss"

highlightStyleDefault = breezeDark
highlightStyleJson = "style.json"

versionHeader = "header"
versionSlug = "slug"
versionMenu = "menu"
versionBody = "body"

--------------------------------------------------------------------------------
-- Business logic

pop [] = []
pop xs = init xs

last' :: [a] -> a
last' [a] = a
last' (a : as) = last' as

applyFlexColumn = applyTernaryTemplate flexColumnTemplate
applyFlexRow = applyTernaryTemplate flexRowTemplate

applyLayoutTemplate :: FileTree (Identifier, Metadata) -> Context String -> Item String -> Compiler (Item String)
applyLayoutTemplate metaTree ctx item = do
    let ident = itemIdentifier item

    let [identHeader, identBody, identMenu] =
            flip setVersion ident . Just
                <$> [ versionHeader
                    , versionBody
                    , versionMenu
                    ]

    bodyHeader <- loadBody identHeader :: Compiler String
    [body, menu] <- mapM load [identBody, identMenu] :: Compiler [Item String]

    menuHeader <- makeEmptyItem >>= loadAndApplyTemplate "templates/sidebar/header.html" ctx >>= return . itemBody :: Compiler String
    footer <- loadBody "footer.html"

    let panel header footer scrollCtx columnCtx =
            loadAndApplyTemplate flexScrollTemplate scrollCtx
                >=> applyFlexColumn header footer columnCtx

    body' <- panel (Just bodyHeader) Nothing ctx (constField "class" "body" <> ctx) body
    menu' <- panel (Just menuHeader) Nothing ctx (constField "class" "menu divider-right" <> ctx) menu

    makeItem (itemBody body')
        >>= applyFlexRow (Just (itemBody menu')) Nothing ctx
        >>= applyFlexColumn Nothing (Just footer) ctx
        >>= loadAndApplyTemplate documentTemplate ctx

-- Static assets (images, fonts, etc.)
staticAssets = match staticAssetPattern $ do
    route idRoute
    compile copyFileCompiler

-- Colocated page assets
pageAssets = match pageAssetPattern $ do
    route parentRoute
    compile copyFileCompiler

-- Post Context
postCtx :: Context String
postCtx = dateField "date" "%B %e, %Y" `mappend` defaultContext

-- Templates
templates = match templatePattern $ compile templateBodyCompiler

-- Hoist the provided route one directory upward
parentRoute =
    customRoute $
        replaceDirectory
            <*> joinPath . drop 1 . splitPath . takeDirectory
            <$> toFilePath

recursiveRoute = composeRoutes (setExtension "html") parentRoute

makeIdentTree fileTree = do
    let isIndex = (== "index") . takeBaseName

    let indexBranches a = case a of
            Branch a as -> Branch (a </> "index.md") (indexBranches <$> as)
            Leaf a -> Leaf a

    let fileTree' = uncurry (</>) . swap <$> tag fileTree
    let fileTree'' = filterFileTree (not . isIndex) fileTree'
    fromFilePath <$> indexBranches fileTree''

makeMetaTree =
    mapM
        ( \a -> do
            meta <- getMetadata a
            return (a, meta)
        )

foldDetails (Branch a as) = H.details H.! A.open "" $ H.toHtml a <> mconcat (foldDetails <$> as)
foldDetails (Leaf a) = H.toHtml a

makeEmptyItem = makeItem ""

slugCompiler ctx =
    makeEmptyItem
        >>= loadAndApplyTemplate
            slugTemplate
            ctx

main :: IO ()
main = do
    -- Hakyll composition
    hakyll $ do
        config <- getMetadata $ fromFilePath "config" :: Rules Metadata

        -- TODO: Use this below, will likely need a refactor around monadic Maybe
        let highlightPath = parseMaybe (.: "highlightStyle") config :: Maybe String

        pandocStyle <- tryLoadStyle highlightStyleDefault highlightStyleJson
        let pandocCompiler' = pandocCompilerWithStyle pandocStyle

        sassHandling pandocStyle cssTemplate "css/**.scss"

        templates
        staticAssets
        pageAssets

        -- wallpapers landscapeWallpaperPattern portraitWallpaperPattern

        -- Create tree structure
        fileTree <- makeFileTree ("pages/**.md" .||. "pages/**.html")
        -- error $ show fileTree
        let identTree = makeIdentTree fileTree
        -- error $ show identTree
        metaTree <- makeMetaTree identTree
        -- error $ show metaTree

        -- Build page breadcrumb data, compiler
        breadcrumbs <- buildTagsWith getBreadcrumb recursivePagesPattern $ fromCapture "**/index.md"
        -- error $ showTags breadcrumbs

        let routes a = case a of
                Branch a as -> [a] <> concatMap routes as
                Leaf a -> [a | matches ("**.md" .||. "**.html") a]

        let pages a = case a of
                Branch a as -> concatMap pages as
                Leaf a -> [a | matches ("**.md" .||. "**.html") a]

        let categories a = do
                let children a = case a of
                        Branch a as -> [a]
                        Leaf a -> [a]

                case a of
                    Branch a as -> [(a, concatMap children as)] <> concatMap categories as
                    Leaf a -> []

        -- Compile footer
        match "footer.html" $ compile getResourceBody

        -- Compile headers, menus
        let slugCtx =
                field
                    "url"
                    ( return
                        . flip replaceExtension "html"
                        . ("/" ++)
                        . joinPath
                        . tail
                        . splitDirectories
                        . toFilePath
                        . itemIdentifier
                    )

        let fieldMaybeIcon def =
                field
                    "icon"
                    ( \a -> do
                        let id = itemIdentifier a
                        icon <- getMetadataField id "icon"
                        return $ fromMaybe def icon
                    )

        let fieldMaybeIconColor def =
                field
                    "icon-color"
                    ( \a -> do
                        let id = itemIdentifier a
                        color <- getMetadataField id "icon-color"
                        return $ fromMaybe def color
                    )

        let pageCtx =
                breadcrumbField "breadcrumb" breadcrumbs
                    <> fieldMaybeIcon "file"
                    <> fieldMaybeIconColor "white"
                    <> defaultContext

        let categoryCtx =
                breadcrumbFieldWith (getBreadcrumbWith pop) "breadcrumb" breadcrumbs
                    <> fieldMaybeIcon "custom-folder"
                    <> fieldMaybeIconColor "purple"
                    <> defaultContext

        match (fromList $ routes identTree) $ do
            version versionMenu $ do
                compile $ do
                    menuTree metaTree
                        >>= makeItem . renderHtml . H.nav . foldDetails

            version versionHeader $ do
                compile $ do
                    makeEmptyItem >>= loadAndApplyTemplate headerTemplate pageCtx

            route recursiveRoute
            compile $
                makeEmptyItem
                    >>= applyLayoutTemplate metaTree pageCtx
                    >>= relativizeUrls

        --- Specialized compilers
        let providers =
                defaultProviders
                    & withCompiler "None" getResourceBody
                    & withCompiler "Default" pandocCompiler'
                    & withCompiler "pandoc" pandocCompiler'
                    & withContext "None" defaultContext

        let spec a b c = CompilerSpec providers $ CompilerDefaults a b c

        let categories' = Data.Map.fromList $ categories identTree

        -- Compile pages
        let pageSpec = spec pandocCompiler' pageCtx postTemplate

        match (fromList $ pages identTree) $ do
            version versionBody $ do
                compile $
                    overridableCompiler pageSpec

            version versionSlug $
                compile $
                    slugCompiler (slugCtx <> pageCtx)

        -- Compile categories
        let bodyCompiler = do
                ident <- getUnderlying
                let ident' = setVersion Nothing ident
                let pat = fromList $ fromMaybe mempty $ Data.Map.lookup ident' categories'

                let catDefaults = CompilerDefaults
                let catSpec =
                        spec
                            pandocCompiler'
                            ( listField "posts" postCtx (loadAll pat)
                                <> categoryCtx
                            )
                            categoryTemplate

                overridableCompiler catSpec

        match (fromList $ Data.Map.keys categories') $ do
            version versionBody $ do
                compile bodyCompiler

            version versionSlug $ do
                compile $
                    slugCompiler (slugCtx <> categoryCtx)