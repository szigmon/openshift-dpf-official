# Chapter 10: DPU Telemetry (DTS) Observability on OpenShift

This chapter describes how to deploy the DOCA Telemetry Service (DTS) on a DPF/OCP cluster and view DPU hardware telemetry (PCIe link, uplink throughput, packets, errors, NIC channels) — first using the native OpenShift console, then optionally using Grafana.

DTS runs on every DPU and exposes DPU counters (sysfs/ethtool) on a Prometheus metrics endpoint. Those metrics are scraped by OpenShift's built-in user-workload monitoring — so on OCP you do not need to install a separate Prometheus.

**Note**: Neither the DPF operator nor the DTS DPUService installs Grafana on OpenShift. Red Hat does not offer a certified Grafana operator — the community Grafana Operator (from OperatorHub) is the standard way to run Grafana on OpenShift.

## 10.1 How DPF exposes DTS metrics to the management cluster

DTS runs on the DPU (hosted) cluster, but Prometheus runs on the management cluster. DPF bridges this with a built-in mechanism: a DPUService's `configPorts` makes DPF publish the service port as a NodePort on the DPU cluster and mirror it as a Service on the management cluster (labeled `dpu.nvidia.com/exposed-port-for-dpucluster`). The management-cluster Prometheus then scrapes that mirror Service. Nothing extra is required — this is how DTS metrics become reachable.

### 10.1.1 Prerequisites

- A deployed DPF/OCP cluster with at least one provisioned DPU.
- `oc` logged in to the management cluster as cluster-admin.
- User-workload monitoring enabled (Step 1 below).

### 10.1.2 Step 1 — Enable OpenShift user-workload monitoring

OpenShift ships with Prometheus, but by default it only monitors OpenShift's own components. To allow it to scrape user namespaces (where DPF and DTS live, e.g. `dpf-operator-system`), enable user-workload monitoring (UWM). This is done by setting `enableUserWorkload: true` in the `cluster-monitoring-config` ConfigMap in the `openshift-monitoring` namespace.

Apply the following ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
```

```bash
$ oc apply -f cluster-monitoring-config.yaml
```

If the ConfigMap already exists with other settings, do not overwrite it — edit it instead and add the `enableUserWorkload: true` line:

```bash
$ oc -n openshift-monitoring edit configmap cluster-monitoring-config
```

Enabling UWM makes OpenShift spin up a dedicated monitoring stack in the `openshift-user-workload-monitoring` namespace. Verify the pods are running:

```bash
$ oc -n openshift-user-workload-monitoring get pods
# Expect: prometheus-user-workload-*, thanos-ruler-user-workload-*,
#         prometheus-operator-*  (all Running)
```

The DTS DPUServiceTemplate, DPUServiceConfiguration, and DPUDeployment are created in section 5.4.3. The `configPorts` declaration in the DPUServiceConfiguration (port `httpserverport: 9189`) is what triggers DPF to mirror the DTS metrics endpoint to the management cluster.

### 10.1.3 Step 2 — Tell Prometheus to scrape DTS

A ServiceMonitor points UWM Prometheus at the DTS metrics endpoint. It uses relabeling to dynamically match any DTS service regardless of the generated name suffix (e.g. `doca-telemetry-service-bqvp6`):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: doca-telemetry-service-monitor
  namespace: dpf-operator-system
spec:
  selector:
    matchExpressions:
      - key: dpu.nvidia.com/dpuservice-name
        operator: Exists
  endpoints:
    - port: httpserverport
      interval: 30s
      path: /metrics
      relabelings:
        - sourceLabels:
            - __meta_kubernetes_service_label_dpu_nvidia_com_dpuservice_name
          regex: doca-telemetry-service.*
          action: keep
  namespaceSelector:
    matchNames:
      - dpf-operator-system
```

```bash
$ oc apply -f dts-servicemonitor.yaml
```

This ServiceMonitor selects services with any `dpu.nvidia.com/dpuservice-name` label, then keeps only those matching `doca-telemetry-service.*`. It scrapes `/metrics` on the `httpserverport` every 30 seconds.

### 10.1.4 Step 3 — Apply the DTS console dashboard

The native OpenShift console can display dashboards under **Observe > Dashboards** without Grafana. This works by creating a ConfigMap in the `openshift-config-managed` namespace with the label `console.openshift.io/dashboard: "true"` — the console monitoring plugin discovers it automatically and adds it to the dashboard dropdown.

Apply the following ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dpf-dts-console-dashboard
  namespace: openshift-config-managed
  labels:
    console.openshift.io/dashboard: "true"
data:
  doca-dpu-telemetry-dts.json: |
    {
      "title": "DOCA DPU Telemetry (DTS)",
      "uid": "doca-dpu-telemetry-dts-console",
      "editable": false,
      "schemaVersion": 16,
      "tags": ["dpf", "dpu", "dts", "telemetry"],
      "timezone": "browser",
      "time": {"from": "now-1h", "to": "now"},
      "refresh": "30s",
      "templating": {"list": []},
      "rows": [
        {
          "title": "PCIe / Link",
          "showTitle": true,
          "height": "250px",
          "panels": [
            {
              "type": "graph", "title": "PCIe Link Speed (GT/s)", "span": 6,
              "datasource": "prometheus", "nullPointMode": "null",
              "legend": {"show": true},
              "yaxes": [{"format": "none", "show": true}, {"format": "none", "show": false}],
              "targets": [
                {"refId": "A", "format": "time_series", "intervalFactor": 2,
                 "expr": "current_link_speed", "legendFormat": "{{source}} {{hca}}"}
              ]
            },
            {
              "type": "graph", "title": "PCIe Link Width (lanes)", "span": 6,
              "datasource": "prometheus", "nullPointMode": "null",
              "legend": {"show": true},
              "yaxes": [{"format": "none", "show": true}, {"format": "none", "show": false}],
              "targets": [
                {"refId": "A", "format": "time_series", "intervalFactor": 2,
                 "expr": "current_link_width", "legendFormat": "{{source}} {{hca}}"}
              ]
            }
          ]
        },
        {
          "title": "Uplink Throughput (p0/p1)",
          "showTitle": true,
          "height": "250px",
          "panels": [
            {
              "type": "graph", "title": "Uplink RX (bits/s)", "span": 6,
              "datasource": "prometheus", "nullPointMode": "null",
              "legend": {"show": true, "values": true, "avg": true, "max": true, "alignAsTable": true, "rightSide": true},
              "yaxes": [{"format": "bps", "show": true}, {"format": "bps", "show": false}],
              "targets": [
                {"refId": "A", "format": "time_series", "intervalFactor": 2,
                 "expr": "sum by(source)(rate({__name__=~\"p[01]_eth_rx_bytes\"}[5m])) * 8",
                 "legendFormat": "{{source}}"}
              ]
            },
            {
              "type": "graph", "title": "Uplink TX (bits/s)", "span": 6,
              "datasource": "prometheus", "nullPointMode": "null",
              "legend": {"show": true, "values": true, "avg": true, "max": true, "alignAsTable": true, "rightSide": true},
              "yaxes": [{"format": "bps", "show": true}, {"format": "bps", "show": false}],
              "targets": [
                {"refId": "A", "format": "time_series", "intervalFactor": 2,
                 "expr": "sum by(source)(rate({__name__=~\"p[01]_eth_tx_bytes\"}[5m])) * 8",
                 "legendFormat": "{{source}}"}
              ]
            }
          ]
        },
        {
          "title": "Uplink Packets & Errors",
          "showTitle": true,
          "height": "250px",
          "panels": [
            {
              "type": "graph", "title": "Uplink packets/s (rx + tx)", "span": 6,
              "datasource": "prometheus", "nullPointMode": "null",
              "legend": {"show": true, "alignAsTable": true, "rightSide": true},
              "yaxes": [{"format": "pps", "show": true}, {"format": "pps", "show": false}],
              "targets": [
                {"refId": "A", "format": "time_series", "intervalFactor": 2,
                 "expr": "sum by(source)(rate({__name__=~\"p[01]_eth_rx_packets\"}[5m]))",
                 "legendFormat": "{{source}} rx"},
                {"refId": "B", "format": "time_series", "intervalFactor": 2,
                 "expr": "sum by(source)(rate({__name__=~\"p[01]_eth_tx_packets\"}[5m]))",
                 "legendFormat": "{{source}} tx"}
              ]
            },
            {
              "type": "graph", "title": "Uplink errors & drops/s", "span": 6,
              "datasource": "prometheus", "nullPointMode": "null",
              "legend": {"show": true, "alignAsTable": true, "rightSide": true},
              "yaxes": [{"format": "cps", "show": true}, {"format": "cps", "show": false}],
              "targets": [
                {"refId": "A", "format": "time_series", "intervalFactor": 2,
                 "expr": "sum by(source)(rate({__name__=~\"p[01]_eth_rx_errors\"}[5m])) + sum by(source)(rate({__name__=~\"p[01]_eth_tx_errors\"}[5m])) + sum by(source)(rate({__name__=~\"p[01]_eth_rx_dropped\"}[5m])) + sum by(source)(rate({__name__=~\"p[01]_eth_tx_dropped\"}[5m])) + sum by(source)(rate({__name__=~\"p[01]_eth_rx_crc_errors\"}[5m]))",
                 "legendFormat": "{{source}}"}
              ]
            }
          ]
        },
        {
          "title": "NIC Channel Activity",
          "showTitle": true,
          "height": "250px",
          "panels": [
            {
              "type": "graph", "title": "NIC channel poll/s", "span": 6,
              "datasource": "prometheus", "nullPointMode": "null",
              "legend": {"show": true, "alignAsTable": true, "rightSide": true},
              "yaxes": [{"format": "cps", "show": true}, {"format": "cps", "show": false}],
              "targets": [
                {"refId": "A", "format": "time_series", "intervalFactor": 2,
                 "expr": "sum by(source)(rate(ch_poll[5m]))", "legendFormat": "{{source}}"}
              ]
            },
            {
              "type": "graph", "title": "NIC channel events/s", "span": 6,
              "datasource": "prometheus", "nullPointMode": "null",
              "legend": {"show": true, "alignAsTable": true, "rightSide": true},
              "yaxes": [{"format": "cps", "show": true}, {"format": "cps", "show": false}],
              "targets": [
                {"refId": "A", "format": "time_series", "intervalFactor": 2,
                 "expr": "sum by(source)(rate(ch_events[5m]))", "legendFormat": "{{source}}"}
              ]
            }
          ]
        }
      ]
    }
```

```bash
$ oc apply -f dts-console-dashboard.yaml
```

**Note**: This dashboard renders against the platform Thanos/UWM Prometheus — no Grafana dependency.

### 10.1.5 Step 4 — Verify the DTS DPUService is up

Confirm the DTS DPUService is Ready on the management cluster. The object name carries a generated suffix (e.g. `doca-telemetry-service-89p28`), so select it by its stable label instead:

```bash
$ oc -n dpf-operator-system get dpuservice \
    -l svc.dpu.nvidia.com/dpudeployment-service=doca-telemetry-service
NAME                           READY   PHASE     AGE
doca-telemetry-service-89p28   True    Success   5m
```

`READY: True` / `PHASE: Success` means DTS is deployed and running.

#### a. View in the native OpenShift console

No Grafana required — the OpenShift console reads the cluster's own Prometheus.

**Quick check (ad-hoc query).** Console > **Observe** > **Metrics**, then enter a DTS query and click **Run queries**:

```
current_link_speed{job=~"doca-telemetry-service.*"}
```

You should get one series per DPU. Hover a line to see its labels — note `source`, which is the DPU node name (how you tell DPUs apart). Other useful queries:

```
rate(p0_eth_rx_bytes{job=~"doca-telemetry-service.*"}[5m]) * 8   # uplink RX bits/s
rate(ch_poll{job=~"doca-telemetry-service.*"}[5m])               # NIC channel activity
```

**Dashboard view.** Console > **Observe** > **Dashboards** > in the Dashboard dropdown select **"DOCA DPU Telemetry (DTS)"**. It shows PCIe link speed/width, uplink throughput, packets/s, errors & drops/s, and NIC channel activity, with each DPU as its own line.

#### b. View in Grafana (optional)

Grafana provides richer dashboards with per-DPU dropdown filters and customizable panels. To use Grafana, install the community Grafana Operator and deploy a Grafana instance with a Prometheus datasource.

**Step 1 — Install the Grafana Operator:**

Create a Subscription to install the Grafana Operator from OperatorHub:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: openshift-operators
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

```bash
$ oc apply -f grafana-operator-subscription.yaml
```

Wait for the operator to install (this can take several minutes for the bundle to unpack):

```bash
$ oc get csv -n openshift-operators | grep grafana
grafana-operator.v5.x.x   Grafana Operator   5.x.x   Succeeded
```

If the OLM bundle unpacking times out (`DeadlineExceeded`), install via Helm instead:

```bash
$ oc delete subscription grafana-operator -n openshift-operators 2>/dev/null || true
$ helm upgrade -i grafana-operator oci://ghcr.io/grafana/helm-charts/grafana-operator \
    --version 5.24.0 \
    --namespace grafana-operator \
    --create-namespace
```

**Step 2 — Create Grafana RBAC for Prometheus access:**

Create a ServiceAccount with a long-lived token and bind it to the `cluster-monitoring-view` ClusterRole so Grafana can query the platform Prometheus:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana-prometheus-reader
  namespace: dpf-operator-system
---
apiVersion: v1
kind: Secret
metadata:
  name: grafana-prometheus-reader-token
  namespace: dpf-operator-system
  annotations:
    kubernetes.io/service-account.name: grafana-prometheus-reader
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-prometheus-reader-cluster-monitoring
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
  - kind: ServiceAccount
    name: grafana-prometheus-reader
    namespace: dpf-operator-system
```

```bash
$ oc apply -f grafana-rbac.yaml
```

**Step 3 — Deploy the Grafana instance:**

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: dpf-grafana
  namespace: dpf-operator-system
  labels:
    dashboards: "dpf-grafana"
spec:
  route:
    spec:
      port:
        targetPort: grafana
      tls:
        termination: edge
  config:
    log:
      mode: "console"
      level: "info"
    auth.anonymous:
      enabled: "true"
      org_role: "Viewer"
    security:
      admin_user: "admin"
      admin_password: "admin"
```

```bash
$ oc apply -f grafana-cr.yaml
```

**Warning**: The default credentials (`admin`/`admin`) are suitable for lab environments only. Change the `admin_password` for non-lab deployments.

**Step 4 — Configure the Prometheus datasource:**

The datasource uses `valuesFrom` to inject the ServiceAccount token directly from the Secret — no manual token substitution required:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus
  namespace: dpf-operator-system
spec:
  instanceSelector:
    matchLabels:
      dashboards: "dpf-grafana"
  valuesFrom:
    - targetPath: "secureJsonData.httpHeaderValue1"
      valueFrom:
        secretKeyRef:
          name: grafana-prometheus-reader-token
          key: token
  datasource:
    name: prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      tlsSkipVerify: true
      httpHeaderName1: "Authorization"
      timeInterval: "30s"
    secureJsonData:
      httpHeaderValue1: "Bearer ${token}"
```

```bash
$ oc apply -f grafana-datasource.yaml
```

**Note**: The `valuesFrom` field tells the Grafana Operator to read the token from the `grafana-prometheus-reader-token` Secret and inject it into `secureJsonData.httpHeaderValue1` at runtime, replacing `${token}`. No manual `sed` or token extraction is needed.

**Step 5 — Deploy the DTS Grafana dashboard:**

The DTS Grafana dashboard adds a dedicated view for DPU hardware telemetry with per-DPU dropdown filters. It consists of a ConfigMap containing the dashboard JSON and a GrafanaDashboard CR that loads it into the Grafana instance:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dpf-dts-grafana-dashboard
  namespace: dpf-operator-system
  labels:
    app.kubernetes.io/part-of: dpf
data:
  doca-dpu-telemetry-dts.json: |
    {
      "title": "DOCA DPU Telemetry (DTS)",
      "uid": "doca-dpu-telemetry-dts",
      "tags": ["dpf", "dpu", "dts", "telemetry"],
      "timezone": "browser",
      "schemaVersion": 39,
      "editable": true,
      "time": {"from": "now-1h", "to": "now"},
      "refresh": "30s",
      "templating": {
        "list": [
          {
            "name": "source",
            "label": "DPU (source)",
            "type": "query",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "query": "label_values(current_link_speed, source)",
            "refresh": 2,
            "includeAll": true,
            "multi": true,
            "current": {"text": "All", "value": "$__all"},
            "sort": 1
          }
        ]
      },
      "panels": [
        {
          "type": "stat",
          "title": "PCIe Link Speed (GT/s)",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
          "fieldConfig": {"defaults": {"unit": "none"}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value", "graphMode": "none"},
          "targets": [
            {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
             "expr": "current_link_speed{source=~\"$source\"}", "legendFormat": "{{source}} {{hca}}"}
          ]
        },
        {
          "type": "stat",
          "title": "PCIe Link Width (lanes)",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0},
          "fieldConfig": {"defaults": {"unit": "none"}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value", "graphMode": "none"},
          "targets": [
            {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
             "expr": "current_link_width{source=~\"$source\"}", "legendFormat": "{{source}} {{hca}}"}
          ]
        },
        {
          "type": "stat",
          "title": "Max PCIe Link Speed (GT/s)",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 4, "w": 6, "x": 12, "y": 0},
          "fieldConfig": {"defaults": {"unit": "none"}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value", "graphMode": "none"},
          "targets": [
            {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
             "expr": "max_link_speed{source=~\"$source\"}", "legendFormat": "{{source}} {{hca}}"}
          ]
        },
        {
          "type": "stat",
          "title": "Max PCIe Link Width (lanes)",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 4, "w": 6, "x": 18, "y": 0},
          "fieldConfig": {"defaults": {"unit": "none"}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value", "graphMode": "none"},
          "targets": [
            {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
             "expr": "max_link_width{source=~\"$source\"}", "legendFormat": "{{source}} {{hca}}"}
          ]
        },
        {
          "type": "timeseries",
          "title": "Uplink RX throughput (p0/p1)",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
          "fieldConfig": {"defaults": {"unit": "bps", "custom": {"drawStyle": "line", "fillOpacity": 10}}, "overrides": []},
          "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["mean", "max"]}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
             "expr": "sum by(source)(rate({__name__=~\"p[01]_eth_rx_bytes\", source=~\"$source\"}[5m])) * 8",
             "legendFormat": "{{source}}"}
          ]
        },
        {
          "type": "timeseries",
          "title": "Uplink TX throughput (p0/p1)",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4},
          "fieldConfig": {"defaults": {"unit": "bps", "custom": {"drawStyle": "line", "fillOpacity": 10}}, "overrides": []},
          "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["mean", "max"]}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
             "expr": "sum by(source)(rate({__name__=~\"p[01]_eth_tx_bytes\", source=~\"$source\"}[5m])) * 8",
             "legendFormat": "{{source}}"}
          ]
        },
        {
          "type": "timeseries",
          "title": "Uplink packets/s (p0/p1 rx+tx)",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 12},
          "fieldConfig": {"defaults": {"unit": "pps", "custom": {"drawStyle": "line", "fillOpacity": 10}}, "overrides": []},
          "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["mean", "max"]}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
             "expr": "sum by(source)(rate({__name__=~\"p[01]_eth_rx_packets\", source=~\"$source\"}[5m]))",
             "legendFormat": "{{source}} rx"},
            {"refId": "B", "datasource": {"type": "prometheus", "uid": "prometheus"},
             "expr": "sum by(source)(rate({__name__=~\"p[01]_eth_tx_packets\", source=~\"$source\"}[5m]))",
             "legendFormat": "{{source}} tx"}
          ]
        },
        {
          "type": "timeseries",
          "title": "Uplink errors & drops/s (p0/p1)",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 12},
          "fieldConfig": {"defaults": {"unit": "cps", "custom": {"drawStyle": "line", "fillOpacity": 10}}, "overrides": []},
          "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["max"]}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
             "expr": "sum by(source)(rate({__name__=~\"p[01]_eth_rx_errors\", source=~\"$source\"}[5m])) + sum by(source)(rate({__name__=~\"p[01]_eth_tx_errors\", source=~\"$source\"}[5m])) + sum by(source)(rate({__name__=~\"p[01]_eth_rx_dropped\", source=~\"$source\"}[5m])) + sum by(source)(rate({__name__=~\"p[01]_eth_tx_dropped\", source=~\"$source\"}[5m])) + sum by(source)(rate({__name__=~\"p[01]_eth_rx_crc_errors\", source=~\"$source\"}[5m]))",
             "legendFormat": "{{source}}"}
          ]
        },
        {
          "type": "timeseries",
          "title": "NIC channel poll/s",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 20},
          "fieldConfig": {"defaults": {"unit": "cps", "custom": {"drawStyle": "line", "fillOpacity": 10}}, "overrides": []},
          "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["mean", "max"]}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
             "expr": "rate(ch_poll{source=~\"$source\"}[5m])",
             "legendFormat": "{{source}} {{device_name}}"}
          ]
        },
        {
          "type": "timeseries",
          "title": "NIC channel events/s",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 20},
          "fieldConfig": {"defaults": {"unit": "cps", "custom": {"drawStyle": "line", "fillOpacity": 10}}, "overrides": []},
          "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["mean", "max"]}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
             "expr": "rate(ch_events{source=~\"$source\"}[5m])",
             "legendFormat": "{{source}} {{device_name}}"}
          ]
        }
      ]
    }
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: doca-dpu-telemetry-dts
  namespace: dpf-operator-system
spec:
  instanceSelector:
    matchLabels:
      dashboards: "dpf-grafana"
  configMapRef:
    name: dpf-dts-grafana-dashboard
    key: doca-dpu-telemetry-dts.json
```

```bash
$ oc apply -f dts-grafana-dashboard.yaml
```

**Step 6 — Access Grafana:**

```bash
$ echo "https://$(oc -n dpf-operator-system get route dpf-grafana-route -o jsonpath='{.spec.host}')"
```

Open the URL in a browser. Anonymous access is read-only (Viewer role); to edit dashboards, click **Sign in** and use the admin credentials set in the Grafana CR.

Navigate to **Dashboards** and open **"DOCA DPU Telemetry (DTS)"**. Use the **DPU (source)** dropdown at the top to focus on a specific DPU or select All. Adjust the time range (top-right); it refreshes every 30 seconds.

**Note**: If the Grafana Operator bundle fails to unpack (`DeadlineExceeded`) via OLM, the Helm method in Step 1 is the reliable alternative. The native console dashboard (section a) provides equivalent DTS functionality without Grafana.

### 10.1.6 View the DPF framework dashboards

The DPF Operator ships four more dashboards beyond the DTS dashboard above — **DOCA Platform Framework State**, **DPU Detail**, **DPU Fleet Health**, and **Controller Runtime** (plus a framework performance dashboard). These show the overall DPF deployment, per-DPU status, fleet-wide health, and the operator's own metrics.

**Important**: these dashboards do **not** appear automatically. The DPF Helm chart only creates the underlying dashboard JSON as ConfigMaps — but in this deployment `grafana.enabled` is `false`, so the chart creates neither the ConfigMaps nor the Grafana instances. To surface the dashboards in the Grafana instance from the previous section you must apply two things that the chart does not create:

1. **`GrafanaDashboard` custom resources** that load the dashboard JSON into the `dpf-grafana` instance (matched by the `dashboards: "dpf-grafana"` label, same convention the DTS dashboard uses).
2. **The metrics collection stack** — `kube-state-metrics` (which exports DPU/custom-resource metrics) and the `PodMonitor` for the DPF controller manager. Without these, the framework dashboards load but show no data.

All of the manifests below are applied automatically by the openshift-dpf automation (`make deploy-observability`). Apply them manually only when adding observability to an existing cluster.

**Step 1 — Enable user-workload monitoring.** The framework dashboards render against the platform Prometheus, so the UWM ConfigMap from section 10.1.2 must already be applied:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
```

```bash
$ oc apply -f cluster-monitoring-config.yaml
```

**Step 2 — Deploy kube-state-metrics and the DPF controller metrics.** This is the piece the DPF chart does not create. It installs a `kube-state-metrics` instance in `dpf-operator-system` that exports DPU and custom-resource metrics, plus a `PodMonitor` that scrapes the DPF controller manager's `/metrics` endpoint:

```yaml
# kube-state-metrics deployment. dpf-operator-customresourcestate-config (referenced below)
# is created by the DPF Helm chart when kube-state-metrics.enabled=true; if it is missing
# in a manual install, create it from the chart's templates/kube-state-metrics-configmap.yaml.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dpf-host-kube-state-metrics
  namespace: dpf-operator-system
  labels:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/instance: dpf-host-kube-state-metrics
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: kube-state-metrics
      app.kubernetes.io/instance: dpf-host-kube-state-metrics
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-state-metrics
        app.kubernetes.io/instance: dpf-host-kube-state-metrics
    spec:
      serviceAccountName: dpf-host-kube-state-metrics
      containers:
        - name: kube-state-metrics
          image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.18.0
          imagePullPolicy: IfNotPresent
          args:
            - --custom-resource-state-config-file=/etc/customresourcestate/config.yaml
            - --custom-resource-state-only=true
            - --port=8080
            - --telemetry-port=8081
          ports:
            - name: http-metrics
              containerPort: 8080
              protocol: TCP
            - name: telemetry
              containerPort: 8081
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /
              port: 8081
            initialDelaySeconds: 5
            timeoutSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            timeoutSeconds: 5
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: customresourcestate-config
              mountPath: /etc/customresourcestate
              readOnly: true
      volumes:
        - name: customresourcestate-config
          configMap:
            name: dpf-operator-customresourcestate-config
            defaultMode: 420
---
apiVersion: v1
kind: Service
metadata:
  name: dpf-host-kube-state-metrics
  namespace: dpf-operator-system
  labels:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/instance: dpf-host-kube-state-metrics
spec:
  type: ClusterIP
  clusterIP: None
  selector:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/instance: dpf-host-kube-state-metrics
  ports:
    - name: http-metrics
      port: 8080
      targetPort: http-metrics
      protocol: TCP
    - name: telemetry
      port: 8081
      targetPort: telemetry
      protocol: TCP
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: dpf-controller-manager
  namespace: dpf-operator-system
  labels:
    app.kubernetes.io/part-of: dpf
spec:
  namespaceSelector:
    matchNames:
      - dpf-operator-system
  selector:
    matchExpressions:
      - key: dpu.nvidia.com/component
        operator: Exists
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      scheme: https
      authorization:
        type: Bearer
        credentials:
          name: dpf-controller-metrics-reader-token
          key: token
      tlsConfig:
        insecureSkipVerify: true
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_label_dpu_nvidia_com_component]
          regex: ".*-controller-manager"
          action: keep
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dpf-host-kube-state-metrics
  namespace: dpf-operator-system
  labels:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/instance: dpf-host-kube-state-metrics
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kube-state-metrics
      app.kubernetes.io/instance: dpf-host-kube-state-metrics
  endpoints:
    - port: http-metrics
      interval: 30s
      path: /metrics
      honorLabels: true
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dpf-host-kube-state-metrics
  namespace: dpf-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dpf-host-kube-state-metrics
rules:
  - apiGroups:
      - svc.dpu.nvidia.com
      - operator.dpu.nvidia.com
      - provisioning.dpu.nvidia.com
      - storage.dpu.nvidia.com
      - vpc.dpu.nvidia.com
    resources: ["*"]
    verbs: ["list", "watch"]
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dpf-host-kube-state-metrics
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: dpf-host-kube-state-metrics
subjects:
  - kind: ServiceAccount
    name: dpf-host-kube-state-metrics
    namespace: dpf-operator-system
---
# Required by the dpf-controller-manager PodMonitor above, which scrapes the
# controller-manager /metrics endpoint with a bearer token.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dpf-controller-metrics-reader
  namespace: dpf-operator-system
---
apiVersion: v1
kind: Secret
metadata:
  name: dpf-controller-metrics-reader-token
  namespace: dpf-operator-system
  annotations:
    kubernetes.io/service-account.name: dpf-controller-metrics-reader
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dpf-controller-metrics-reader
rules:
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dpf-controller-metrics-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: dpf-controller-metrics-reader
subjects:
  - kind: ServiceAccount
    name: dpf-controller-metrics-reader
    namespace: dpf-operator-system
```

```bash
$ oc apply -f dpf-metrics.yaml
```

**Step 3 — Load the framework dashboards into Grafana.** The DPF Helm chart creates the dashboard JSON as ConfigMaps (`dpf-operator-grafana-dashboards` and `dpf-operator-grafana-debug-dashboards`). The `GrafanaDashboard` custom resources below load each dashboard into the `dpf-grafana` instance. Apply them:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: doca-platform-framework-state
  namespace: dpf-operator-system
spec:
  instanceSelector:
    matchLabels:
      dashboards: "dpf-grafana"
  configMapRef:
    name: dpf-operator-grafana-dashboards
    key: doca-platform-framework-state.json
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: doca-platform-dpu-detail
  namespace: dpf-operator-system
spec:
  instanceSelector:
    matchLabels:
      dashboards: "dpf-grafana"
  configMapRef:
    name: dpf-operator-grafana-dashboards
    key: doca-platform-dpu-detail.json
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: doca-platform-dpu-fleet-health
  namespace: dpf-operator-system
spec:
  instanceSelector:
    matchLabels:
      dashboards: "dpf-grafana"
  configMapRef:
    name: dpf-operator-grafana-dashboards
    key: doca-platform-dpu-fleet-health.json
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: controller-runtime
  namespace: dpf-operator-system
spec:
  instanceSelector:
    matchLabels:
      dashboards: "dpf-grafana"
  configMapRef:
    name: dpf-operator-grafana-debug-dashboards
    key: controller-runtime.json
```

```bash
$ oc apply -f grafana-dashboards.yaml
```

**Verification**

* Verify the kube-state-metrics pod is running:

  ```
  $ oc -n dpf-operator-system get pods -l app.kubernetes.io/name=kube-state-metrics
  ```

* Verify the framework dashboards are loaded into Grafana:

  ```
  $ oc -n dpf-operator-system get grafanadashboard
  ```

  **Example output**

  ```
  NAME                       AGE
  doca-platform-framework-state   ...
  doca-platform-dpu-detail        ...
  doca-platform-dpu-fleet-health  ...
  controller-runtime              ...
  ```

* Open each dashboard in Grafana: **Dashboards** dropdown → **DOCA Platform Framework State**, **DOCA DPU Detail**, **DOCA DPU Fleet Health**, or **Controller Runtime**.

**Note**: The framework dashboards read their data from the kube-state-metrics and controller `PodMonitor` deployed in Step 2. Applying the `GrafanaDashboard` CRs without the metrics stack loads the dashboards but they will show no data. These four dashboards plus the DTS dashboard are all applied together by the openshift-dpf automation; the manual steps above are only needed when adding observability to an existing cluster.
