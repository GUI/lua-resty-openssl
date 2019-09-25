local ffi = require "ffi"

local C = ffi.C
local ffi_gc = ffi.gc
local ffi_new = ffi.new
local ffi_cast = ffi.cast

local _M = {}
local mt = {__index = _M}

require "resty.openssl.ossl_typ"
require "resty.openssl.stack"

ffi.cdef [[
  typedef struct EDIPartyName_st EDIPARTYNAME;

  typedef struct otherName_st OTHERNAME;

  typedef struct GENERAL_NAME_st {
      int type;
      union {
        char *ptr;
        OTHERNAME *otherName;   /* otherName */
        ASN1_IA5STRING *rfc822Name;
        ASN1_IA5STRING *dNSName;
        ASN1_TYPE *x400Address;
        X509_NAME *directoryName;
        EDIPARTYNAME *ediPartyName;
        ASN1_IA5STRING *uniformResourceIdentifier;
        ASN1_OCTET_STRING *iPAddress;
        ASN1_OBJECT *registeredID;
        /* Old names */
        ASN1_OCTET_STRING *ip;  /* iPAddress */
        X509_NAME *dirn;        /* dirn */
        ASN1_IA5STRING *ia5;    /* rfc822Name, dNSName,
                                    * uniformResourceIdentifier */
        ASN1_OBJECT *rid;       /* registeredID */
        ASN1_TYPE *other;       /* x400Address */
      } d;
    } GENERAL_NAME;

  // STACK_OF(GENERAL_NAME)
  typedef struct stack_st GENERAL_NAMES;

  GENERAL_NAME *GENERAL_NAME_new(void);
  void GENERAL_NAME_free(GENERAL_NAME *a);

  // STACK_OF(X509_EXTENSION)
  int X509V3_add1_i2d(OPENSSL_STACK **x, int nid, void *value,
                    int crit, unsigned long flags);
]]
