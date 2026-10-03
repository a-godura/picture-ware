package photos

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/service/cognitoidentityprovider"
)

// CognitoDirectory looks up users' display names in the Cognito user pool.
type CognitoDirectory struct {
	Client     *cognitoidentityprovider.Client
	UserPoolID string
}

// DisplayName returns what other members see for userID (see DisplayName).
// The pool's usernames are the users' subs, so the sub is the username.
func (d *CognitoDirectory) DisplayName(ctx context.Context, userID string) (string, error) {
	out, err := d.Client.AdminGetUser(ctx, &cognitoidentityprovider.AdminGetUserInput{
		UserPoolId: &d.UserPoolID, Username: &userID,
	})
	if err != nil {
		return "", fmt.Errorf("admin get user: %w", err)
	}
	var name, email string
	for _, a := range out.UserAttributes {
		if a.Name == nil || a.Value == nil {
			continue
		}
		switch *a.Name {
		case "name":
			name = *a.Value
		case "email":
			email = *a.Value
		}
	}
	return DisplayName(name, email), nil
}
