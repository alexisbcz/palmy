# Northwind Q4 launch plan

The **Atlas** release ships to every customer in the fourth quarter. This page is the single source of truth for scope, dates and owners; edit it in place rather than forking a copy.

## Goals

- Move every workspace to the new sync engine without downtime.
- Cut median page load to under 400 ms on the reference laptop.
- Publish the migration guide two weeks before general availability.

## Timeline

| Milestone | Owner | Date |
| --- | --- | --- |
| Feature freeze | Alice | Nov 3 |
| Release candidate | Bob | Nov 17 |
| General availability | Alice | Dec 1 |

## Risks

The migration touches every document, so a bad release is visible to everyone at once. We ship behind a flag and widen it over a week.
