# T24 transaction posting process

This document summarizes how a T24/Temenos Transact transaction flows from business input to the point of generating accounting entries and updating balances in the data layer.[cite:58][cite:74]

## Overall processing flow

A transaction typically starts from a business application or an integration channel such as OFS/API, then passes through the Transact processing layer to validate data, apply business logic, and emit accounting events.[cite:58][cite:74]

According to Temenos API documentation, Transact provides events and APIs serving business and accounting domains; this shows that posting is not merely a database write statement but a controlled chain of business processing.[cite:58][cite:74]

## Steps of a posting

### 1. Receive transaction

A transaction may enter from an application such as Funds Transfer or from an integration channel via OFS/API, then be mapped to an internal record for the system to process.[cite:58][cite:59]

### 2. Validation

Before posting, the system checks the validity of the input data, account status, effective date, and related business rules.[cite:59][cite:70]

If validation fails, the transaction is rejected before the posting step is completed.[cite:70]

### 3. Authorization and business processing

After passing validation, the transaction enters the authorization or business commit step, where custom routines may be invoked to add additional checks or enrich data.[cite:70][cite:60]

At this stage, the system determines the type of entries to be generated for the transaction, for example journal entries serving the corresponding accounting event.[cite:74][cite:64]

### 4. Generate accounting entries

Temenos publishes events related to accounting journal entries, indicating that a business transaction will be converted into structured accounting entries for downstream systems or the ledger to process.[cite:74]

In practice within T24, the common entry types mentioned in the overview documentation include statement entry and category entry, depending on the nature of the business operation and the posting objective.[cite:64][cite:66]

### 5. Write data and update balances

After the accounting entries are created, the system records the processing results into the core data layer and updates related information such as balances or transaction history.[cite:59][cite:76]

The important point is that posting in T24 is transaction-oriented: business and accounting changes must be consistent to avoid ledger or balance discrepancies.[cite:76][cite:74]

### 6. Return result

When all processing is complete, the system returns a response to the originating channel, including a success status or a business/technical error.[cite:58][cite:59]

## Understanding "posting to the database" correctly

At a low level, posting can be viewed as the operation of writing records into data tables or files.[cite:59][cite:76]

But at a more accurate architectural level, posting in T24 is a chain consisting of receiving the transaction, validating, authorizing, generating accounting entries, committing changes, and only then reflecting down to the database.[cite:58][cite:74][cite:76]

Therefore, the diagram you provided is reasonable if used to describe the **database posting flow**, but it should be understood that the database is only the final step of a broader business transaction pipeline.[cite:58][cite:74]

## Brief explanation for Funds Transfer

For a money transfer transaction from CA1 to CA2, the system first confirms that the input is valid and the transaction is permitted to be processed, then generates the corresponding debit/credit accounting entries, and finally updates the core data to reflect the new balance.[cite:59][cite:64][cite:74]

This understanding aligns with the event/accounting model that Temenos describes for Transact and also matches the T24 overview documentation regarding accounting behavior.[cite:58][cite:64][cite:74]
