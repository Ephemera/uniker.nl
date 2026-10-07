---
title: How to observe an unikernel
description: Collect and see metrics
---

Unikernels have the distinctive feature of running with a certain degree of
autonomy. It may, however, be necessary to monitor these unikernels - in
particular, to know how much memory they are using, how they are utilising
their vCPUs, and also to keep an eye on network activity.

In this chapter, we will look specifically at how to install various tools for
monitoring unikernels. In this case, we will install:
- [InfluxDB][influxdb] to collect metrics
- [Telegraf][telegraf], which allows us to bridge the gap between
  `albatross_stats` and InfluxDB
- [Grafana][grafana], which allows us to visualise the metrics

Finally, we will use one of our libraries, [tally][tally], to generate slightly
more specific metrics relating to our unikernels.

[influxdb]: https://www.influxdata.com/
[telegraf]: https://www.influxdata.com/time-series-platform/telegraf/
[grafana]: https://grafana.com/
[tally]: /packages/tally
