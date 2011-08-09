{-# LANGUAGE FlexibleInstances, UndecidableInstances,
             OverlappingInstances, ScopedTypeVariables #-}

module Foreign.OpenCL.Bindings.Util where

import Foreign
import Foreign.C.Types
import Foreign.C.String

import Foreign.OpenCL.Bindings.Types
import Foreign.OpenCL.Bindings.Error

-- A class for retrieving information about different OpenCL objects.
-- Exports getInfo which is polymorhic in its output
class ClGetInfo a where
  getInfo :: (Enum i, Integral b) => (b -> ClSize -> Ptr () -> Ptr ClSize -> IO ClInt) -> i -> IO a

instance ClGetInfo [Char] where
   getInfo getInfoFun i = genericGetInfo i getInfoFun returnString
     where
       returnString :: ClSize -> Ptr () -> IO String
       returnString bytes ptr = peekCStringLen (castPtr ptr, fromIntegral bytes - 1)

instance Storable a => ClGetInfo a where
   getInfo getInfoFun i = genericGetInfo i getInfoFun returnFun
     where
       returnFun _ ptr = peek $ castPtr ptr

instance ClGetInfo Bool where
  getInfo getInfoFun i = genericGetInfo i getInfoFun returnBool
    where
      returnBool :: ClSize -> Ptr () -> IO Bool
      returnBool _ ptr = do b <- peek $ castPtr ptr
                            return (b /= clFalse)

-- A class for retrieving lists from OpenCL
-- for instance, used in clGetPlatformIDs
class ClGetList a where
  getList :: (ClUInt -> Ptr a -> Ptr ClUInt -> IO ClInt) -> IO [a]

instance Storable a => ClGetList a where
  getList getListFun = alloca $ \num -> do
   -- Figure out how large the list is
   getListFun 0 nullPtr num
   n <- peek num
   -- Get the elements
   allocaArray (fromIntegral n) $ \ptrs -> do
     getListFun n (castPtr ptrs) num
     n' <- peek num
     assert (n == n') "Inconsistent number of retrieved elements"
     peekArray (fromIntegral n') ptrs

-- Calls "getInfoFun" to retrieve information about some OpenCL
-- object. Then hands the resulting data in form of a pointer and size
-- to the "handler".
--
-- All OpenCL information-query function follows the same style:
--   * First they are queried to determine size of the output
--   * Then the actual output can be queried
genericGetInfo :: (Enum i, Integral b)
               => i
               -> (b -> ClSize -> Ptr () -> Ptr ClSize -> IO ClInt)
               -> (ClSize -> Ptr () -> IO a)
               -> IO a
genericGetInfo info getInfoFun handler =
  let info_code = fromIntegral $ fromEnum info
  in alloca $ \bytes_ret -> do
       -- Determine the size of info
       getInfoFun info_code 0 nullPtr bytes_ret
       bytes <- peek bytes_ret
       -- Get the info
       allocaBytes (fromIntegral bytes) $ \info_ptr -> do
         getInfoFun info_code bytes info_ptr bytes_ret
         bytes' <- peek bytes_ret
         assert (bytes == bytes') "Inconsistent number of retrived bytes"
         handler bytes' info_ptr

enumToBitfield :: (Bits a, Integral a, Enum b) => [b] -> a
enumToBitfield = foldr ((.|.) . fromIntegral . fromEnum) 0

-- | Look at a list of foreign pointers, ensuring the pointers are not
-- freed for at least the duration of the computation.
withForeignPtrs :: forall a b. [ForeignPtr a] -> ([Ptr a] -> IO b) -> IO b
withForeignPtrs ptrs f = with' ptrs []
  where
    with' :: [ForeignPtr a] -> [Ptr a] -> IO b
    with' [] ys = f (reverse ys)
    with' (p:ps) ys = withForeignPtr p $ \p' -> with' ps (p':ys)

-- | Create a null terminated array of values from a Haskell list.
withArrayNull :: Storable a => [a] -> (Ptr a -> IO b) -> IO b
withArrayNull [] f = f nullPtr
withArrayNull xs f = withArray xs f

-- | Create a null terminated array of values from a Haskell list, and
-- compute the length of the list simultaneously.
withArrayNullLen :: Storable a => [a] -> (Int -> Ptr a -> IO b) -> IO b
withArrayNullLen [] f = f 0 nullPtr
withArrayNullLen xs f = withArrayLen xs f
