# Automating Managed Private Endpoint Approval
Automating the approval of managed private endpoints can be challenging. Since you are reading this article I will assume you already begun to explore managed private endpoints and have discovered a need to automate the approval process. The techniques demonstrated here are centered around a deployment pipeline but they are generic enough to be implemented in other solutions.

## What exactly is a managed private endpoint?

To start with, there is no formal Azure resource type or canonical representation so we'll have come up with our own unofficial definition. A managed private endpoint (MPE) is a regular private endpoint (PE) that is provisioned on our behalf inside the managed network of a PaaS resource. Some PaaS resources that offer MPEs are: Azure Stream Analytics, Azure Data Explorer, and Azure Data Factory. There are others but we'll stick with these for now.

Along with the lack of a formal definition MPEs are also inconsistently implemented across PaaS resources within Azure. I suspect that the following three factors have contributed to the inconsistencies.
1. The aforementioned lack of a formal definition.
2. The need of the PaaS resource to protect its VNeT and the managed resources within it.
3. The fact that private endpoints have an asynchronous approval workflow.

Before we dive in let's take a look at some key Azure Private Link terminology. If you are familiar Azure Private Link terminology feel free to skip this section.
For now let's roughly define Azure Private Link as a private connection **from** a VNet **to** a **target resource**.

**Private Endpoint (PE)** refers to the outbound virtual NIC and IP address within the virtual network. The virtual network may be your own or a managed VNet. You may think of the PE as the "from" part of the definition.
    
**Private Endpoint Connection (PEC)** refers to the inbound private connection at the target resource. This makes the PEC the "to" part of the definition.
    
**Private Link Resource (PLR)** refers to the resource we are trying to connect to, and so the PRL is the target resource.

A large number of Azure resources support Private Link. In other words, a lot of Azure resources support being the target resource in a Private Link Connection. On the other hand, few Azure PaaS resources support MPEs. Those that support MPEs can connect to any resource that supports Private Link. 

## MPE workflow

Going back to our informal definition of an MPE we understand that an MPE is realized by provisioning a PE inside a managed network. This means MPEs inherit the idiosyncrasies of PEs, including the [asynchronous approval workflow](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview#access-to-a-private-link-resource-using-approval-workflow). 

MPEs add more complexity to the approval workflow. First, we have to wait for the PaaS resource to provision the PE before we can attempt to approve the PEC at the target resource. Second, the implementation of MPE varies by PaaS resources and we have to account for the particular behavior of each PaaS resource. For example, Stream Analytics uses one data model when returning the MPE status and Data Explorer uses a different model. Data Factory uses a different model still. To make matters worse each services uses different values to describe the status of the MPE. We'll dive into the various implementation details later.

The following diagram illustrates the steps associated with approving an MPE. Parts of the process are asynchronous and there are two loops to follow. I suggest that you read along the description of each step as you navigate the diagram.

![mpe workflow](/media/mpe-workflow.svg)

1. Client (automation pipeline) request the MPE from the PaaS resource by sending the resource id of the target. The PaaS resource creates a stub for the MPE in pending status and immediate returns the MPE's resource id. The reason why the PaaS resource returns the MPE in pending status before the underlying PE is ready to use is because the approval of the PEC is an asynchronous process outside the control of the PaaS resource. The PaaS resource has no way of knowing how long the approval process will take. So the PaaS resource puts the burden of ensuring the PEC is approved on the client.
2. The PaaS resource begins the process of provisioning the PE in its managed network. There are a few steps involved in provisioning of a PE but they are out of scope for our discussion.
3. It will take some time for the PaaS resource to provision the PE. Exactly how long will depend on the PaaS resource and the target resource. For example when creating an MPE from Stream Analytics to a Storage Account I found the PE would be provisioned in a few seconds (less than 5 seconds typically), while provisioning an MPE from Stream Analytics to IoT Hub took over 30 seconds, sometimes over a minute. In this step we have to operate in a loop consisting of these steps: get the MPE status, evaluate the status, possibly wait, and finally proceed accordingly.
4. The implementation of the MPE status loop is the most important part of automating the approval of MPEs. As they say the devil is in the details and there are lots of details here. Let's dive in.
    1. **Avoid a race condition**: At first glance you may think that the point of this whole ordeal is to approve the PEC at the target resource, so why should we care about the status of the MPE? Why don't we simply query the target resource for the status of the PEC and approve the PEC as soon as possible? The reason why we can't skip checking the status of the MPE before approving the PEC is because certain PaaS resources will consider the MPE to be in an invalid state if the PEC goes from Provisioning to Approved, thus skipping the Pending Approval status from the perspective of the PaaS resource. Remember that provisioning the MPE is an asynchronous process, if we go behind the MPE to approve the PEC before the MPE realizes the PEC is in Pending status our deployment pipeline has effectively entered into a race condition with the PaaS resource. Being a race condition means that sometimes this approach will work but it will be inconsistent. And after all, isn't the point of automating deployments to provide consistent results.
   2. **Different data models**: As mentioned earlier each PaaS resource implements MPE differently. When we query the MPE status from Stream Analytics, Data Explorer, and Data Factory we get a different data model (JSON document) from each of these PaaS resources. That's a bummer but we can work around that with some custom mapping code.
   1. **Different status values**: The last factor and possibly the most critical is that each PaaS resource reports the status of the MPE using different values. Stream Analytics reports the status of the MPE as: PendingCreation, PendingCustomerApproval, and SetUpComplete. Personally I find these statuses to be self-describing and easy to work with. On the other hand, Data Explorer returns the MPE status as: Provisioning or Succeeded. We can safely assume what 'Provisioning' means but what exactly does 'Succeeded' mean? Does it mean the PEC is pending approval or that it was already approved and ready for use? In order to determine if the PEC is pending approval we must use some custom translation code and heuristics for each PaaS resource on top of the custom mapping code from the previous step.
5. Sometime later the PaaS resource will update the status of the MPE according to their own timeline. When this happens then the loop above may exit and the deployment pipeline my move forward with the process.
6. At this stage the MPE is reporting a status that we can interpret as 'the PEC is pending approval'. Approving the PEC should be as easy as calling the appropriate API (PowerShell, Azure CLI, Azure REST API) but no such luck here. Because the status of the MPE reported by the PaaS resources can be ambiguous (looking at you Azure Data Explorer) we have to get the status of the PEC directly from the target resource before we approve the PEC lest we risk raising an exception.
7. Call the your preferred API to approve the PEC… all done!

Something to note in the process above, not once did we interact with the PE directly. I am specifically calling this out to point out the managed nature of the MPEs. We interact with the MPE at the PaaS resource and we can interact with the PEC at the target resource, but we never interact with the PE directly.

## Permissions to approve PEC when using Bicep

As you've seen we don't really approve MPEs, we approve the corresponding PECs. The story around the permissions needed to approve a PEC in the context of a deployment pipeline written in Bicep is a bit nuance. I assume that the security principal used to operate the pipeline has enough permissions to create the MPEs. The catch however is that we need a couple of loops and custom scripting to get the status of the MPEs and eventually approve the PEC. If you are using Bicep this means we need to use a [deployment script](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deployment-script-template) if we want to approve the PECs in line with the rest of the resources. One reason to this would be if you want to deploy MPEs and approve the corresponding PEC before you deploy a Stream Analytics job that depends on the MPEs. Deploying an Azure Data Factory Pipelines would be similar use case.

Deployment scripts require a user managed identity to operate. If we follow the principal of least privilege then our custom deployment script may not use the same security principal that is operating the deployment pipeline. This means we need to provision a dedicated user managed identity with the appropriate permissions. A discussion on RBAC an particularly RBAC scopes is out of scope, so I will summarize the permissions needed in plain language:
1. Read permissions on PaaS resource in order to query the status of the MPEs
2. Read permission on the target resource in order to query the status of the PECs
3. '*…/privateEndpointConnections/write*' permission on target resource.
    1. For some examples of these write permission see the accompanying sample code.

## Sample code

The accompanying sample code includes a bicep script that will deploy a set of Azure resources designed to illustrate all the challenges described in this article (4.i, 4.ii, 4.iii). The bicep script also includes a sample PowerShell script that implements the loops and custom mapping code. Last but not least, the bicep script deploys the necessary resources to execute the PowerShell script using a deployment script. The sample is a complete proof of concept that could easily be adapted for production use.

I urge you to examine the bicep script for details that were not covered in the narrative portion of this article. For example, Azure Data Factory appends the name of the data factory to the MPE name while Stream Analytics and Data Explorer does not. Good luck and happy automating.
