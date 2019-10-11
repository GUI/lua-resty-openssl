local ffi = require "ffi"

local C = ffi.C
local ffi_gc = ffi.gc
local ffi_new = ffi.new
local ffi_cast = ffi.cast
local ffi_str = ffi.string
local null = ngx.null

local evp_lib = require "resty.openssl.evp"
require "resty.openssl.rsa"
require "resty.openssl.ec"
local bn_lib = require "resty.openssl.bn"
require "resty.openssl.bio"
require "resty.openssl.pem"
local util = require "resty.openssl.util"
require "resty.openssl.x509"
local format_error = require("resty.openssl.err").format_error

local OPENSSL_11 = require("resty.openssl.version").OPENSSL_11

local function generate_key(config)
  local ctx = C.EVP_PKEY_new()
  if ctx == nil then
    return nil, "EVP_PKEY_new() failed"
  end

  local type = config.type or 'RSA'

  local code, failure

  if type == "RSA" then
    local bits = config.bits or 2048
    if bits > 4294967295 then
      return nil, "bits out of range"
    end
    local exp = C.BN_new()
    if exp == nil then
      return nil, "BN_new() failed"
    end
    C.BN_set_word(exp, config.exp or 65537)
    local rsa = C.RSA_new()
    if rsa == nil then
      C.BN_free(exp)
      return nil, "RSA_new() failed"
    end
    code = C.RSA_generate_key_ex(rsa, bits, exp, nil)
    if code ~= 1 then
      failure = 'RSA_generate_key_ex'
      goto rsa_pkey_free
    end
    code = C.EVP_PKEY_set1_RSA(ctx, rsa)
    if code ~= 1 then
      failure = 'EVP_PKEY_set1_RSA'
      goto rsa_pkey_free
    end
::rsa_pkey_free::
    C.BN_free(exp)
    C.RSA_free(rsa)
    if code ~= 1 then
      return nil, "error in " .. failure
    end
  elseif type == "EC" then
    local curve = config.curve or 'prime192v1'
    local nid = C.OBJ_ln2nid(curve)
    if nid == 0 then
      return nil, "unknown curve " .. curve
    end
    local group = C.EC_GROUP_new_by_curve_name(nid)
    if group == nil then
      return nil, "EC_GROUP_new_by_curve_name() failed"
    end
    -- # define OPENSSL_EC_NAMED_CURVE     0x001
    C.EC_GROUP_set_asn1_flag(group, 1)
    C.EC_GROUP_set_point_conversion_form(group, C.POINT_CONVERSION_UNCOMPRESSED)
    local key = C.EC_KEY_new()
    if key == nil then
      C.EC_GROUP_free(group)
      return nil, "EC_KEY_new() failed"
    end

    C.EC_KEY_set_group(key, group);
    C.EC_GROUP_free(group)

    local code = C.EC_KEY_generate_key(key)
    if code == 0 then
			C.EC_KEY_free(key);
			return nil, "EC_KEY_generate_key() failed"
		end

    C.EVP_PKEY_set1_EC_KEY(ctx, key)
		C.EC_KEY_free(key);
  else
    return nil, "unsupported type " .. type
  end

  return ctx, nil
end

local load_pkey_try_args_pem = { null, null, null }
local load_pkey_try_args_der = { null }

local load_pkey_try_funcs = {
  PEM = {
    -- Note: make sure we always try load priv key first
    pr = {
      ['PEM_read_bio_PrivateKey'] = load_pkey_try_args_pem,
    },
    pu = {
      ['PEM_read_bio_PUBKEY'] = load_pkey_try_args_pem,
    },
  },
  DER = {
    pr = {
      ['d2i_PrivateKey_bio'] = load_pkey_try_args_der,
    },
    pu = {
      ['d2i_PUBKEY_bio'] = load_pkey_try_args_der,
    },
  }
}
-- populate * funcs
local all_funcs = {}
local typ_funcs = {}
for fmt, ffs in pairs(load_pkey_try_funcs) do
  local funcs = {}
  for typ, fs in pairs(ffs) do
    for f, arg in pairs(fs) do
      funcs[f] = arg
      all_funcs[f] = arg
      if not typ_funcs[typ] then
        typ_funcs[typ] = {}
      end
      typ_funcs[typ] = arg
    end
  end
  load_pkey_try_funcs[fmt]["*"] = funcs
end
load_pkey_try_funcs["*"] = {}
load_pkey_try_funcs["*"]["*"] = all_funcs
for typ, fs in pairs(typ_funcs) do
  load_pkey_try_funcs[typ] = fs
end

local function load_pkey(txt, fmt, typ)
  fmt = fmt or '*'
  if fmt ~= 'PEM' and fmt ~= 'DER' and fmt ~= '*' then
    return nil, "expecting 'DER', 'PEM' or '*' at #2"
  end

  typ = typ or '*'
  if typ ~= 'pu' and typ ~= 'pr' and typ ~= '*' then
    return nil, "expecting 'pr', 'pu' or '*' at #3"
  end

  ngx.log(ngx.DEBUG, "load key using fmt: ", fmt, ", type: ", typ)

  local bio = C.BIO_new_mem_buf(txt, #txt)
  if bio == nil then
    return "BIO_new_mem_buf() failed"
  end
  ffi_gc(bio, C.BIO_free)

  local ctx

  local fs = load_pkey_try_funcs[fmt][typ]
  for f, arg in pairs(fs) do
    -- #define BIO_CTRL_RESET 1
    local code = C.BIO_ctrl(bio, 1, 0, nil)
    if code ~= 1 then
      return nil, "BIO_ctrl() failed"
    end

    ctx = C[f](bio, unpack(arg))
    if ctx ~= nil then
      ngx.log(ngx.DEBUG, "loaded pkey using ", f)
      break
    end
  end

  if ctx == nil then
    return nil, format_error("pkey.new:load_pkey")
  end
  return ctx, nil
end

local PEM_write_bio_PrivateKey_args = { null, null, 0, null, null }
local PEM_write_bio_PUBKEY_args = {}

local function tostring(self, fmt)
  local method
  if fmt == 'private' or fmt == 'PrivateKey' then
    method = 'PEM_write_bio_PrivateKey'
  elseif not fmt or fmt == 'public' or fmt == 'PublicKey' then
    method = 'PEM_write_bio_PUBKEY'
  else
    return nil, "can only export private or public key, not " .. fmt
  end

  local args
  if method == 'PEM_write_bio_PrivateKey' then
    args = PEM_write_bio_PrivateKey_args
  else
    args = PEM_write_bio_PUBKEY_args
  end

  return util.read_using_bio(method, self.ctx, unpack(args))
end

local _M = {}
local mt = { __index = _M, __tostring = tostring }

-- type
-- bits
-- exp
-- curve
function _M.new(s, ...)
  local ctx, err, has_private
  s = s or {}
  if type(s) == 'table' then
    ctx, err = generate_key(s)
  elseif type(s) == 'string' then
    ctx, err = load_pkey(s, ...)
  else
    return nil, "unexpected type " .. type(s) .. " at #1"
  end

  if err then
    return nil, err
  end

  local key_size = C.EVP_PKEY_size(ctx)

  if err then
    return nil, err
  end

  local self = setmetatable({
    ctx = ctx,
    -- has_private = has_private,
    key_size = key_size,
  }, mt)

  ffi_gc(ctx, C.EVP_PKEY_free)

  return self, nil
end

local empty_table = {}
local bnptr_type = ffi.typeof("const BIGNUM *[1]")
local function get_rsa_params_11(pkey)
  -- {"n", "e", "d", "p", "q", "dmp1", "dmq1", "iqmp"}
  local rsa_st = C.EVP_PKEY_get0_RSA(pkey)
  if rsa_st == nil then
    return nil, "EVP_PKEY_get0_RSA() failed"
  end

  return setmetatable(empty_table, {
    __index = function(tbl, k)
      if k == 'n' then
        local bnptr = bnptr_type()
        C.RSA_get0_key(rsa_st, bnptr, nil, nil)
        return bn_lib.new(bnptr[0]), nil
      elseif k == 'e' then
        local bnptr = bnptr_type()
        C.RSA_get0_key(rsa_st, nil, bnptr, nil)
        return bn_lib.new(bnptr[0]), nil
      elseif k == 'd' then
        local bnptr = bnptr_type()
        C.RSA_get0_key(rsa_st, nil, nil, bnptr)
        return bn_lib.new(bnptr[0]), nil
      end
    end
  }), nil
end

local function get_rsa_params_10(pkey)
  -- {"n", "e", "d", "p", "q", "dmp1", "dmq1", "iqmp"}

  return setmetatable(empty_table, {
    __index = function(tbl, k)
      if k == 'n' then
        return bn_lib.new(pkey.pkey.rsa.n), nil
      elseif k == 'e' then
        return bn_lib.new(pkey.pkey.rsa.e), nil
      elseif k == 'd' then
        return bn_lib.new(pkey.pkey.rsa.d), nil
      end
    end
  }), nil
end

function _M:getParameters()
  local key_type = C.EVP_PKEY_base_id(self.ctx)
  if key_type == evp_lib.EVP_PKEY_RSA then
    if OPENSSL_11 then
      return get_rsa_params_11(self.ctx)
    else
      return get_rsa_params_10(self.ctx)
    end
  elseif key_type == evp_lib.EVP_PKEY_EC then
    return nil, "parameters of EC not supported"
  end

  return nil, "key type not supported"
end

local uint_ptr = ffi.typeof("unsigned int[1]")

function _M:sign(digest)
  local buf = ffi_new('unsigned char[?]', self.key_size)
  local length = uint_ptr()
  local code = C.EVP_SignFinal(digest.ctx, buf, length, self.ctx)
  return ffi_str(buf, length[0]), nil
end

function _M:verify(signature, digest)
  local code = C.EVP_VerifyFinal(digest.ctx, signature, #signature, self.ctx)
  if code == 0 then
    return false, nil
  elseif code == 1 then
    return true, nil
  end
  return false, "EVP_VerifyFinal() failed"
end

function _M:toPEM(pub_or_priv)
  return tostring(self, pub_or_priv)
end

return _M