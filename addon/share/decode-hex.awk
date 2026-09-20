# Input is length-checked lowercase hex. C locale makes %c byte-oriented.
BEGIN { digits="0123456789abcdef" }
{
    for (i=1; i<=length($0); i+=2) {
        a=index(digits,substr($0,i,1))-1; b=index(digits,substr($0,i+1,1))-1
        if (a<0 || b<0) exit 1
        printf "%c", a*16+b
    }
}
