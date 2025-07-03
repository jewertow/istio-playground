### TODO


#### 1. OpenShift Router is used only in some source clusters

Scenario:
- a service is imported from multiple remote meshes;
- some of the source meshes use OpenShift Router to expose exported services, and other do not;

Possible solutions:

1. The destination rule for SNI customization could be managed by mesh-admin chart and applied only to relevant routes. **Disadvantage**: this approach would require mesh admin to apply namespace-admin values from all namespaces.
2. Endpoints in imported service entries could include `mesh` label used to define subsets and then the destination rules would customize SNI only in relevant subsets.
