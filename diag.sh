#!/bin/bash
# Narrows the exact `limit` boundary on Spotify search, and confirms results
# actually come back. Prints no secrets.
S=SpotifyKaraoke.SpotifyAPI

ID=$(security find-generic-password -s "$S" -a clientID -w 2>/dev/null) || exit 1
SECRET=$(security find-generic-password -s "$S" -a clientSecret -w 2>/dev/null) || exit 1
TOKEN=$(curl -s -u "$ID:$SECRET" -d grant_type=client_credentials \
    https://accounts.spotify.com/api/token \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "token failed"; exit 1; }
echo "token: ${#TOKEN} chars"

probe() {
    local label="$1" url="$2"
    local resp code body n total
    resp=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" "$url")
    code=$(printf '%s' "$resp" | tail -1)
    body=$(printf '%s' "$resp" | sed '$d')
    if [ "$code" = "200" ]; then
        # format-agnostic: count track URIs however the JSON is spaced
        n=$(printf '%s' "$body" | grep -o 'spotify:track:' | wc -l | tr -d ' ')
        total=$(printf '%s' "$body" | sed -n 's/.*"total"[: ]*\([0-9]*\).*/\1/p' | head -1)
        printf "  %-12s HTTP %s   items=%-4s total=%s\n" "$label" "$code" "$n" "${total:-?}"
    else
        printf "  %-12s HTTP %s   %s\n" "$label" "$code" \
            "$(printf '%s' "$body" | sed -n 's/.*"message"[: ]*"\([^"]*\)".*/\1/p')"
    fi
    sleep 0.3
}

BASE="https://api.spotify.com/v1/search?q=hello&type=track"
echo "== narrowing the boundary =="
for n in 10 11 12 13 14 15 16 17 18 19 20; do
    probe "limit=$n" "$BASE&limit=$n"
done

echo "== sanity: does a plain search return real tracks? =="
probe "(no limit)" "$BASE"
echo "== first track name returned =="
curl -s -H "Authorization: Bearer $TOKEN" "$BASE&limit=5" \
    | sed -n 's/.*"name"[: ]*"\([^"]*\)".*/\1/p' | head -3
