// Package legacy holds the pre-trips API (/photos, photos keyed by user) and
// its DynamoDB table, unchanged, so the currently shipped app keeps working
// while clients move to /trips. Delete it once no client calls /photos.
package legacy
