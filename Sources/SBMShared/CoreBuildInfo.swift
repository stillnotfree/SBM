public enum CoreBuildInfo {
  public static let version = "1.14.4"
  public static let revision = "c005f35300ce76427dc285481ec5695f5b179cd2"
  public static let goVersion = "go1.26.10"
  public static let buildTags = "with_clash_api,with_quic,with_utls"
  public static let cgo = "enabled"
  public static let linkerFlags =
    "-X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0"
  public static let signedSize: Int64 = 36_547_920
  public static let unsignedSHA256 =
    "e6c632427680cf74b4e8b578f35ff1954629e0f26627ab4d5c867e5ca1135884"
  public static let signedSHA256 =
    "0973840a5d884ac9217bdd35befba3a91949bd5c7da5675664086b6db13f3267"
}
