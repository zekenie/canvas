// The ten schemas the card was designed against (the prototype's fixtures, scratchpad/card-proto), in
// its order: a new card, flat ones, twenty fields, nesting, four levels, long names, $defs and oneOf
// and patternProperties and if/then, and a text that isn't JSON.

let fixtures: [(name: String, json: String)] = [
    ("1 new card", #"{"type":"object","properties":{}}"#),

    ("2 contact", #"""
    {
      "title": "Contact",
      "type": "object",
      "properties": {
        "email": { "type": "string", "format": "email" },
        "phone": { "type": "string" },
        "description": { "type": "string" }
      },
      "required": ["email", "phone"]
    }
    """#),

    ("3 pet", #"""
    {
      "title": "Pet",
      "type": "object",
      "properties": {
        "name": { "type": "string" },
        "species": { "type": "string", "enum": ["dog", "cat", "bird", "fish", "other"] },
        "birthYear": { "type": "integer", "minimum": 1900 },
        "coatColor": { "type": "string" },
        "vaccinated": { "type": "boolean" }
      },
      "required": ["name", "species"]
    }
    """#),

    ("4 seven flat", #"""
    {
      "title": "Book",
      "type": "object",
      "properties": {
        "title": { "type": "string" },
        "author": { "type": "string" },
        "isbn": { "type": "string", "pattern": "^[0-9-]{10,17}$" },
        "pages": { "type": "integer", "minimum": 1 },
        "publishedOn": { "type": "string", "format": "date" },
        "genre": { "enum": ["fiction", "nonfiction", "poetry", "drama"] },
        "inPrint": { "type": "boolean" }
      },
      "required": ["title", "author"]
    }
    """#),

    ("5 twenty fields", #"""
    {
      "title": "Customer",
      "type": "object",
      "properties": {
        "id": { "type": "string", "format": "uuid" },
        "firstName": { "type": "string" },
        "lastName": { "type": "string" },
        "email": { "type": "string", "format": "email" },
        "phone": { "type": "string" },
        "company": { "type": "string" },
        "jobTitle": { "type": "string" },
        "website": { "type": "string", "format": "uri" },
        "street": { "type": "string" },
        "city": { "type": "string" },
        "region": { "type": "string" },
        "postalCode": { "type": "string" },
        "country": { "type": "string" },
        "birthday": { "type": "string", "format": "date" },
        "loyaltyTier": { "enum": ["bronze", "silver", "gold", "platinum"] },
        "points": { "type": "integer", "minimum": 0 },
        "marketingOptIn": { "type": "boolean" },
        "notes": { "type": "string" },
        "createdAt": { "type": "string", "format": "date-time" },
        "updatedAt": { "type": "string", "format": "date-time" }
      },
      "required": ["id", "firstName", "lastName", "email"]
    }
    """#),

    ("6 order", #"""
    {
      "title": "Order",
      "type": "object",
      "properties": {
        "id": { "type": "string" },
        "customer": {
          "type": "object",
          "properties": {
            "name": { "type": "string" },
            "email": { "type": "string", "format": "email" }
          },
          "required": ["name"]
        },
        "items": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "sku": { "type": "string" },
              "quantity": { "type": "integer", "minimum": 1 },
              "price": { "type": "number" }
            },
            "required": ["sku", "quantity"]
          }
        },
        "shippingAddress": {
          "type": "object",
          "properties": {
            "street": { "type": "string" },
            "city": { "type": "string" },
            "postalCode": { "type": "string" },
            "country": { "type": "string" }
          }
        },
        "status": { "type": "string", "enum": ["pending", "paid", "shipped", "delivered", "cancelled"] },
        "createdAt": { "type": "string", "format": "date-time" }
      },
      "required": ["id", "customer", "items", "status"]
    }
    """#),

    ("7 four levels", #"""
    {
      "title": "Organization",
      "type": "object",
      "properties": {
        "name": { "type": "string" },
        "headquarters": {
          "type": "object",
          "properties": {
            "address": {
              "type": "object",
              "properties": {
                "location": {
                  "type": "object",
                  "properties": {
                    "lat": { "type": "number" },
                    "lng": { "type": "number" }
                  }
                },
                "city": { "type": "string" },
                "country": { "type": "string" }
              }
            },
            "phone": { "type": "string" }
          }
        },
        "founded": { "type": "integer" },
        "tags": { "type": "array", "items": { "type": "string" } }
      },
      "required": ["name"]
    }
    """#),

    ("8 long names", #"""
    {
      "title": "Quarterly Enterprise Subscription Renewal Request Form",
      "type": "object",
      "properties": {
        "primaryAccountManagerEmailAddress": { "type": "string", "format": "email" },
        "annualContractValueInUnitedStatesDollars": { "type": "number", "minimum": 0 },
        "numberOfSeatsRequestedForNextBillingPeriod": { "type": "integer" },
        "preferredInvoiceDeliveryMethodAndSchedule": { "enum": ["email-monthly", "email-quarterly", "postal-quarterly", "portal"] },
        "hasSignedTheUpdatedDataProcessingAgreement": { "type": "boolean" }
      },
      "required": ["primaryAccountManagerEmailAddress", "annualContractValueInUnitedStatesDollars"]
    }
    """#),

    ("9 power features", #"""
    {
      "title": "Payment",
      "type": "object",
      "$defs": {
        "money": {
          "type": "object",
          "properties": {
            "amount": { "type": "number" },
            "currency": { "type": "string", "pattern": "^[A-Z]{3}$" }
          },
          "required": ["amount", "currency"]
        }
      },
      "properties": {
        "total": { "$ref": "#/$defs/money" },
        "method": {
          "oneOf": [
            { "title": "Card", "type": "object", "properties": { "cardNumber": { "type": "string" }, "expiry": { "type": "string" } } },
            { "title": "Bank transfer", "type": "object", "properties": { "iban": { "type": "string" } } },
            { "title": "Wallet", "type": "object", "properties": { "provider": { "type": "string" } } }
          ]
        },
        "country": { "type": "string" },
        "vatNumber": { "type": "string" }
      },
      "patternProperties": { "^x-": { "type": "string" } },
      "required": ["total", "method"],
      "if": { "properties": { "country": { "const": "DE" } } },
      "then": { "required": ["vatNumber"] }
    }
    """#),

    ("10 invalid json", #"""
    {
      "title": "Invoice",
      "type": "object",
      "properties": {
        "number": { "type": "string" },
        "amount": { "type": "number", }
        "due": { "type": "string", "format": "date" }
      }
    """#),
]
