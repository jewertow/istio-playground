# Mesh Federation Helm Charts

This directory contains Helm charts for managing Istio mesh federation with support for both direct routing and egress gateway routing.

## Architecture Overview

This solution provides a **two-tier architecture** for managing mesh federation:

- **`mesh-admin`**: Cluster-level infrastructure and routing configuration
- **`namespace-admin`**: Application-level service import/export management

This architecture enables mesh administrators to control what is exported from or imported to the cluster, while allowing application developers to control imports into their namespaces and configure the services they wish to export.

### mesh-admin (Infrastructure Layer)
Manages **cluster-level mesh federation infrastructure** including:
- Ingress gateway configuration for exporting services to remote meshes
- Egress gateway configuration for importing services from remote meshes (optional)
- Service entries for remote mesh ingresses (defines how to reach remote meshes)
- Virtual services for load balancing across multiple remote meshes and control the egress traffic
- OpenShift routes for routing traffic through the cluster ingress (optional)

**Deployed by**: Platform administrators  
**Scope**: Cluster-wide (typically in `istio-system` namespace)
**Purpose**: Specify available meshes and services, which can be imported and exported

### namespace-admin (Application Layer)
Manages **namespace-level service imports and exports**:
- Service entries for imported services (namespace-scoped, points to egress gateway or remote endpoints)
- Service entries for exported services with workload selectors (namespace-scoped)
- Virtual services for routing imported services through egress gateway (when enabled)

**Deployed by**: Application developers/teams  
**Scope**: Namespace  
**Purpose**: Import/export local services
**Dependencies**: Inherits configuration from `mesh-admin` through `global` values

## How the Charts Work Together

The resource created by the `namespace-admin` chart **depend on** the resources created by the `mesh-admin` chart, so values for the `namespace-admin` should always be merged with values for the `mesh-admin`.

### Configuration Flow

1. **mesh-admin** defines the infrastructure:

   ```yaml
   # mesh-admin values
   global:
     egressGateway:
       enabled: true
       selector:
         app: istio-egressgateway
     remote:
     - mesh: west-mesh
       addresses: [192.168.2.10]
       network: west-network
       importedServices:
       - ratings.mesh.global
   ```

2. **namespace-admin** inherits `global` config and adds application-specific imports:
   ```yaml
   # namespace-admin values (merged with mesh-admin)
   global:
     # ... inherited from mesh-admin
   import:
   - hostname: ratings.mesh.global
   ```

3. **Result**: `namespace-admin` creates ServiceEntry that routes to egress gateway, which then routes to remote mesh based on `mesh-admin` configuration.

### Deployment Patterns

**Pattern 1: Merged Values (Recommended)**
```shell
helm install app-services namespace-admin/ \
  -f mesh-admin-values.yaml \
  -f namespace-values.yaml \
  --namespace my-app
```

**Pattern 2: Configuration Composition**
```shell
helm install namespace-federation namespace-admin/ \
  --set-file global=<(helm get values mesh-federation) \
  -f namespace-imports.yaml
```

## Configuration Examples

### Step 1: Configure mesh-admin (Platform Administrator)

```yaml
# mesh-admin-values.yaml
global:
  configNamespace: istio-system
  egressGateway:
    enabled: true
    selector:
      istio: egressgateway
  defaultServicePorts:
  - number: 9080
    name: http
    protocol: HTTP
  remote:
  - mesh: west-mesh
    addresses:
    - 192.168.2.10
    - 192.168.2.11
    port: 15443
    network: west-network
    locality: us-west-1
    importedServices:
    - httpbin.mesh.global
    - ratings.mesh.global
  - mesh: central-mesh
    addresses:
    - 192.168.3.10
    port: 15443
    network: central-network
    locality: us-central-1
    importedServices:
    - ratings.mesh.global
```

**Deploy mesh-admin:**
```shell
helm install mesh-federation mesh-admin/ -f mesh-admin-values.yaml
```

### Step 2: Configure namespace-admin (Application Developer)

```yaml
# app-namespace-values.yaml
# Note: global config is inherited from mesh-admin
import:
- hostname: ratings.mesh.global
- hostname: httpbin.mesh.global
  ports:
  - number: 8000
    name: http
    protocol: HTTP
export:
- hostname: productpage.mesh.global
  labelSelector:
    app: productpage
```

**Deploy namespace-admin:**
```bash
# Deploy with merged configurations
helm install bookinfo-services namespace-admin/ \
  -f mesh-admin-values.yaml \
  -f app-namespace-values.yaml \
  --namespace bookinfo
```

### What Gets Created

**From mesh-admin (cluster-wide):**
- Egress Gateway for routing to remote meshes
- ServiceEntries for `ingress.west-mesh.global` and `ingress.central-mesh.global`
- VirtualServices for load balancing `ratings` traffic across west-mesh and central-mesh
- VirtualService routing `httpbin` traffic to west-mesh only

**From namespace-admin (namespace-scoped):**
- ServiceEntry `httpbin.mesh.global` pointing to egress gateway
- ServiceEntry `ratings.mesh.global` pointing to egress gateway  
- ServiceEntry `productpage.mesh.global` that exports pods with `app: productpage` labels

