#!/usr/bin/env bash
# Optional CLI check that mirrors the manual console test:
# insert items, read one by key, query both GSIs, update, then delete.
# Usage: ./scripts/verify-table.sh dev|prod [region]
set -euo pipefail

ENVIRONMENT="${1:?usage: $0 dev|prod [region]}"
REGION="${2:-eu-west-1}"
TABLE="books-catalog-${ENVIRONMENT}-books"

echo "== Table description"
aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" \
  --query "Table.{Name:TableName,Status:TableStatus,Billing:BillingModeSummary.BillingMode,Class:TableClassSummary.TableClass,GSIs:GlobalSecondaryIndexes[].IndexName}"

echo "== Put items"
put() {
  aws dynamodb put-item --table-name "$TABLE" --region "$REGION" --item "$1"
}
put '{"BookId":{"S":"cli-test-001"},"Title":{"S":"Things Fall Apart"},"Author":{"S":"Chinua Achebe"},"Genre":{"S":"Fiction"},"PublishedYear":{"N":"1958"}}'
put '{"BookId":{"S":"cli-test-002"},"Title":{"S":"Arrow of God"},"Author":{"S":"Chinua Achebe"},"Genre":{"S":"Fiction"},"PublishedYear":{"N":"1964"}}'
put '{"BookId":{"S":"cli-test-003"},"Title":{"S":"A Brief History of Time"},"Author":{"S":"Stephen Hawking"},"Genre":{"S":"Science"},"PublishedYear":{"N":"1988"}}'

echo "== Get item by primary key"
aws dynamodb get-item --table-name "$TABLE" --region "$REGION" \
  --key '{"BookId":{"S":"cli-test-001"}}'

# GSIs are eventually consistent; give them a moment to catch up.
sleep 2

echo "== Query AuthorIndex (Author = Chinua Achebe)"
aws dynamodb query --table-name "$TABLE" --region "$REGION" \
  --index-name AuthorIndex \
  --key-condition-expression "Author = :a" \
  --expression-attribute-values '{":a":{"S":"Chinua Achebe"}}' \
  --query "Items[].Title.S"

echo "== Query GenreIndex (Genre = Science)"
aws dynamodb query --table-name "$TABLE" --region "$REGION" \
  --index-name GenreIndex \
  --key-condition-expression "Genre = :g" \
  --expression-attribute-values '{":g":{"S":"Science"}}' \
  --query "Items[].Title.S"

echo "== Update item"
aws dynamodb update-item --table-name "$TABLE" --region "$REGION" \
  --key '{"BookId":{"S":"cli-test-003"}}' \
  --update-expression "SET Genre = :g" \
  --expression-attribute-values '{":g":{"S":"Non-Fiction"}}' \
  --return-values UPDATED_NEW

echo "== Delete test items"
for id in cli-test-001 cli-test-002 cli-test-003; do
  aws dynamodb delete-item --table-name "$TABLE" --region "$REGION" \
    --key "{\"BookId\":{\"S\":\"$id\"}}"
done
echo "Done."
