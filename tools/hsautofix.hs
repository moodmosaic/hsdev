module Main (
	main
	) where

import Control.Lens (each, view, preview)
import Control.Arrow ((***))
import Control.Monad (liftM)
import Data.Aeson
import Data.List (partition, sort)
import Data.Maybe (mapMaybe)
import System.Directory (canonicalizePath)
import Text.Read (readMaybe)

import HsDev.Symbols (Canonicalize(..), moduleFile)
import HsDev.Tools.Base
import HsDev.Tools.AutoFix
import HsDev.Tools.GhcMod (parseOutputMessages)
import HsDev.Util (toUtf8, liftE, readFileUtf8, writeFileUtf8, ordNub)

import Tool

main :: IO ()
main = toolMain "hsautofix" [
	jsonCmd "show" [] [jsonArg] "show what can be auto-fixed" show',
	jsonCmd "fix" [] [nList, pureArg] "fix selected errors" fix']
	where
		nList = list "num" "index" `short` ['n'] `desc` "corrrection indices to apply, if nothing specified - all corrections applies"
		pureArg = flag "pure" `desc` "don't modify files, just return updated rest corrections"
		jsonArg = flag "json" `desc` "output messages in JSON format"

		show' :: Args -> ToolM [Note Correction]
		show' (Args _ as) = do
			input <- liftE getContents
			msgs <- if flagSet "json" as
				then maybe (toolError "Can't parse messages") return $ decode (toUtf8 input)
				else return $ parseOutputMessages input
			mapM (liftE . canonicalize) $ corrections msgs

		fix' :: Args -> ToolM [Note Correction]
		fix' (Args [] as) = do
			input <- liftE getContents
			corrs <- maybe (toolError "Can't parse messages") return $ decode (toUtf8 input)
			let
				nums :: [Int]
				nums = mapMaybe readMaybe $ listArg "num" as
				check i
					| has "num" as = i `elem` nums
					| otherwise = True
				(fixCorrs, upCorrs) = (map snd *** map snd) $ 
					partition (check . fst) $ zip [1..] corrs
			files <- liftE $ mapM canonicalizePath $ ordNub $ sort $ mapMaybe (preview $ noteSource . moduleFile) corrs
			let
				doFix :: FilePath -> EditM String [Note Correction]
				doFix file = grouped $ do
					autoFix_ fixCorrs'
					(each . note) update upCorrs'
					where
						findCorrs :: FilePath -> [Note Correction] -> [Note Correction]
						findCorrs f = filter ((== Just f) . preview (noteSource . moduleFile))
						fixCorrs' = map (view note) $ findCorrs file fixCorrs
						upCorrs' = findCorrs file upCorrs
				runFix file
					| flagSet "pure" as = return $ fst $ edit "" $ doFix file
					| otherwise = do
						(corrs', cts') <- liftM (`edit` doFix file) $ liftE $ readFileUtf8 file
						liftE $ writeFileUtf8 file cts'
						return corrs'
			liftM concat $ mapM runFix files
		fix' _ = toolError "Invalid arguments"
