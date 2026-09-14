# Split only complete PEM CERTIFICATE blocks, never arbitrary file contents.
function reject() { invalid = 1; exit 1 }
{
    sub(/\r$/, "")
    if ($0 == "-----BEGIN CERTIFICATE-----") {
        if (inside) reject()
        inside = 1
        count++
        filename = sprintf("%s/cert-%04d.pem", directory, count)
        print >filename
        next
    }
    if ($0 == "-----END CERTIFICATE-----") {
        if (!inside) reject()
        print >filename
        close(filename)
        inside = 0
        next
    }
    if (inside) {
        if ($0 !~ /^[A-Za-z0-9+\/=]+$/) reject()
        print >filename
    } else if ($0 !~ /^[ \t]*$/) {
        reject()
    }
}
END { if (invalid || inside || count == 0) exit 1 }
