/// The Overkiz Root CA, which signs the certificate of every TaHoma, Connexoon and Switch gateway's local API (Somfy's
/// Developer Mode). Somfy's developer documentation (github.com/Somfy-Developer/Somfy-TaHoma-Developer-Mode, "TLS
/// certificate") says to trust it, and publishes it at https://ca.overkiz.com/overkiz-root-ca-2048.crt, where this copy
/// comes from. Subject `O=Overkiz, OU=Root CA, CN=Overkiz Root CA, C=FR`, valid from 2016-04-27 to 2036-04-27, SHA-256
/// fingerprint `BB:FA:96:11:1E:AE:15:E3:C6:ED:15:F3:43:27:6C:0C:27:26:03:2E:A1:9D:F5:BB:D0:67:E2:F1:CF:FC:44:DB`, as
/// docs/clean-room/Tahoma.md (3.4) gives it; `TahomaTests` checks the fingerprint.
enum OverkizRootCA {
    static let pem = """
-----BEGIN CERTIFICATE-----
MIIDPDCCAiSgAwIBAgIJAOvswclbF4QnMA0GCSqGSIb3DQEBCwUAMEsxEDAOBgNV
BAoTB092ZXJraXoxEDAOBgNVBAsTB1Jvb3QgQ0ExGDAWBgNVBAMTD092ZXJraXog
Um9vdCBDQTELMAkGA1UEBhMCRlIwHhcNMTYwNDI3MTI1ODE1WhcNMzYwNDI3MTI1
ODE1WjBLMRAwDgYDVQQKEwdPdmVya2l6MRAwDgYDVQQLEwdSb290IENBMRgwFgYD
VQQDEw9PdmVya2l6IFJvb3QgQ0ExCzAJBgNVBAYTAkZSMIIBIjANBgkqhkiG9w0B
AQEFAAOCAQ8AMIIBCgKCAQEAsszRfbcNCEoD9ZfzTbXfuMK8CrXGqBR/ZOCk4guN
aRKqZ/rLQm3V6Q+dlJ/8qle5J3KN5bZmqT4qXKHwJsaOiLfPyAptSM6vuIlls2N+
UsKkv3m5+gTyLaSGMS4wh2GoOCa21V9t5wYUQnoFaQByVNyl+kkrWLpKw5gQasU0
xkVsjAVKgkkb3puBl7sZgiSoz97I9U9JUkg3spH0I84CZRI+JejioDHvkZEyf83j
+QFxSTV/hZkUwUY/X0zt2dTZuliCTePeCdANryo6+9TbBp98j/SB1s59FcO8NSSK
sV07rTFlM9/soko2/J0aTtXHE86wFq7vfFVZzZxsQpIBbwIDAQABoyMwITAPBgNV
HRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEA
GU7xUWlZZEVnEK0k3Z1FoRl9xA7cLOiDVCQ5qQDFfQgGpMtXv1PKsQNZ6T6tZN3d
bdzsqcQXtLhXknz6aGBZNR4g6liQhVuCaiyURaI+LM2KuSZnbixs3+1SPBvxHrJh
/gOsxctxq+0DALnOK9qbGl6N5DtjM/EC5Qve71c+UVTEcJjJ3L2S1Ne+PxDOJuUC
JsOLUk96G+uLn6CQB5Wu8fYrkWAjF3yrxkCoZCqOvVrnbL77vXmz2mlqNHSJt3Ur
ndWJLVvrRFKdSG6WiNCh/Q+ARQAorN60JD9x8+IyXRGvlZl7KVeRduE2rjZuom7h
QLMnmaF+oFW5mnhh9gu6Gg==
-----END CERTIFICATE-----
"""

    static let sha256Fingerprint = "bbfa96111eae15e3c6ed15f343276c0c2726032ea19df5bbd067e2f1cffc44db"
}
