#!/bin/bash

# Script to create a domain and user account in Stalwart
# Usage: ./setup-account.sh [port]

PORT=${1:-8080}
BASE_URL="http://localhost:$PORT"
AUTH="admin:admin"

echo "Setting up domain and account on port $PORT"
echo "============================================"
echo ""

# Step 1: Create domain
echo "1. Creating domain: example.com"
DOMAIN_RESPONSE=$(curl -s --request POST \
  --url "$BASE_URL/api/principal" \
  --header "authorization: Basic $(echo -n $AUTH | base64)" \
  --header 'content-type: application/json' \
  --data '{
  "type": "domain",
  "name": "example.com",
  "description": "Primary mail domain"
}')

echo "Domain creation response:"
echo "$DOMAIN_RESPONSE" | jq '.' 2>/dev/null || echo "$DOMAIN_RESPONSE"
echo ""

# Check if domain creation was successful
DOMAIN_ID=$(echo "$DOMAIN_RESPONSE" | jq -r '.data // empty' 2>/dev/null)
if [ -n "$DOMAIN_ID" ] && [ "$DOMAIN_ID" != "null" ]; then
    echo "✓ Domain created successfully (ID: $DOMAIN_ID)"
else
    # Check if domain already exists or if there's an error
    if echo "$DOMAIN_RESPONSE" | grep -q "already exists\|conflict" 2>/dev/null; then
        echo "⚠ Domain already exists, continuing..."
    else
        echo "✗ Failed to create domain"
        exit 1
    fi
fi
echo ""

# Step 2: Create user account
echo "2. Creating user: alice@example.com"
USER_RESPONSE=$(curl -s --request POST \
  --url "$BASE_URL/api/principal" \
  --header "authorization: Basic $(echo -n $AUTH | base64)" \
  --header 'content-type: application/json' \
  --data '{
  "type": "individual",
  "name": "alice",
  "description": "Alice Doe",
  "emails": [
    "alice@example.com"
  ],
  "secrets": [
    "{PLAIN}supersecret"
  ]
}')

echo "User creation response:"
echo "$USER_RESPONSE" | jq '.' 2>/dev/null || echo "$USER_RESPONSE"
echo ""

# Check if user creation was successful
USER_ID=$(echo "$USER_RESPONSE" | jq -r '.data // empty' 2>/dev/null)
if [ -n "$USER_ID" ] && [ "$USER_ID" != "null" ]; then
    echo "✓ User created successfully (ID: $USER_ID)"
    echo ""
    echo "Account details:"
    echo "  Email: alice@example.com"
    echo "  Password: supersecret"
else
    # Check if user already exists
    if echo "$USER_RESPONSE" | grep -q "already exists\|conflict" 2>/dev/null; then
        echo "⚠ User already exists"
        echo ""
        echo "Account details:"
        echo "  Email: alice@example.com"
        echo "  Password: supersecret"
    else
        echo "✗ Failed to create user"
        exit 1
    fi
fi

echo ""
echo "============================================"
echo "Setup complete!"
echo ""
echo "You can now use these credentials:"
echo "  Username: alice@example.com"
echo "  Password: supersecret"
