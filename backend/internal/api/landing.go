package api

import (
	"bytes"
	"html/template"
	"net/http"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/photos"
)

// The invite landing page is public, so it shows nothing about the trip and
// doesn't even look the code up: it only hands the code to the app. The app
// checks it (GET /invites/{code}) once the person is signed in.
var landingTemplate = template.Must(template.New("landing").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>{{if .Code}}Join a trip on picture-ware{{else}}Link not found{{end}}</title>
<style>
:root{color-scheme:light dark;--bg:#fff;--fg:#1c1c1e;--muted:#6e6e73;--accent:#0a84ff}
@media (prefers-color-scheme:dark){:root{--bg:#000;--fg:#f2f2f7;--muted:#98989d}}
body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.45 -apple-system,system-ui,sans-serif}
main{max-width:28rem;margin:0 auto;padding:4rem 1rem}
h1{font-size:1.6rem;margin:0 0 1rem}
p{color:var(--muted)}
a.button{display:block;margin:2rem 0;padding:.9rem 1rem;border-radius:.8rem;background:var(--accent);color:#fff;text-align:center;font-weight:600;text-decoration:none}
</style>
</head>
<body>
<main>
{{if .Code -}}
<h1>You're invited to a trip</h1>
<p>Someone shared a trip with you on picture-ware, so everyone's photos land on the same map.</p>
<a class="button" href="{{.AppURL}}">Open in picture-ware</a>
<p>Don't have the app yet? Install picture-ware on your iPhone and sign in, then come back and tap this link again.</p>
{{- else -}}
<h1>This invite link isn't valid</h1>
<p>Check that you copied the whole link, or ask for a new one.</p>
{{- end}}
</main>
</body>
</html>
`))

// landingPage renders GET /j/{code}.
func landingPage(code string) events.APIGatewayV2HTTPResponse {
	status := http.StatusOK
	data := struct {
		Code   string
		AppURL template.URL
	}{}
	if photos.ValidInviteCode(code) {
		// The code is [a-z2-7]{26}, so this URL needs no escaping.
		data.Code, data.AppURL = code, template.URL(AppScheme+"://join/"+code)
	} else {
		status = http.StatusNotFound
	}
	var b bytes.Buffer
	if err := landingTemplate.Execute(&b, data); err != nil {
		return events.APIGatewayV2HTTPResponse{StatusCode: http.StatusInternalServerError}
	}
	return events.APIGatewayV2HTTPResponse{
		StatusCode: status,
		Headers: map[string]string{
			"Content-Type":            "text/html; charset=utf-8",
			"Cache-Control":           "no-store",
			"Referrer-Policy":         "no-referrer",
			"X-Robots-Tag":            "noindex",
			"X-Content-Type-Options":  "nosniff",
			"X-Frame-Options":         "DENY",
			"Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
		},
		Body: b.String(),
	}
}
