## Via CLI :
```bash
aws rds reboot-db-instance \
  --region eu-west-1 \
  --db-instance-identifier notes-db \
  --force-failover
```

## Wait for it to finish, then query the events :

```bash
  aws rds describe-events \
  --region eu-west-1 \
  --source-identifier notes-db \
  --source-type db-instance \
  --duration 30 \
  --query "Events[].[Date,EventCategories,Message]" \
  --output table
```
## Output :

```json
    [
        "2026-11-19T18:36:01.592000+00:00",
        [
            "failover"
        ],
        "Multi-AZ instance failover started. "
    ],
    [
        "2026-11-19T18:36:15.060000+00:00",
        [
            "availability"
        ],
        "DB instance restarted"
    ],
    [
        "2026-11-19T18:36:50.130000+00:00",
        [
            "failover"
        ],
        "Multi-AZ instance failover completed"
    ],
```

**Calculate the failover duration:**

Take the timestamp of the failover start event (18:36:01.592) and subtract it from the timestamp of the failover completed event (18:36:50.130).

**Total Failover Duration:** ~48.54