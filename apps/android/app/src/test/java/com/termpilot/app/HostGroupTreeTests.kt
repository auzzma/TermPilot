package com.termpilot.app

import org.junit.Assert.*
import org.junit.Test

class HostGroupTreeTests {
    private val groups=listOf(HostGroupInfo("child","Production","root"),HostGroupInfo("root","Cloud"),HostGroupInfo("leaf","Asia","child"))
    private val hosts=mapOf("root" to listOf("one" to "gateway"),"leaf" to listOf("two" to "database 10.0.0.2"))
    @Test fun nestedGroupsCanBeCollapsedIndependently(){
        val tree=hostGroupTree(groups)
        assertEquals(listOf("group-root","group-child","group-leaf","host-two","host-one"),hostTreeRows(tree,hosts,emptySet(),"").map{it.id})
        val rows=hostTreeRows(tree,hosts,setOf("child"),"")
        assertEquals(listOf("group-root","group-child","host-one"),rows.map{it.id})
        assertEquals(2,rows.first().count)
        assertEquals(listOf("group-root"),hostTreeRows(tree,hosts,setOf("root"),"").map{it.id})
    }
    @Test fun searchRevealsCollapsedAncestorsAndRetainsHierarchy(){
        val rows=hostTreeRows(hostGroupTree(groups),hosts,setOf("root","child"),"database")
        assertEquals(listOf(0,1,2,3),rows.map{it.depth})
        assertEquals("host-two",rows.last().id)
        assertEquals("Cloud / Production / Asia",hostGroupOptions(hostGroupTree(groups)).last().second)
    }
    @Test fun malformedCyclesAndOrphansRemainReachableOnce(){
        val input=listOf(HostGroupInfo("a","A","b"),HostGroupInfo("b","B","a"),HostGroupInfo("c","C","missing"))
        val ids=hostGroupOptions(hostGroupTree(input)).map{it.first}
        assertEquals(setOf("a","b","c"),ids.toSet());assertEquals(3,ids.size)
    }
    @Test fun matchingGroupIncludesItsDescendants(){
        val rows=hostTreeRows(hostGroupTree(groups),hosts,setOf("root"),"Production")
        assertEquals(listOf("group-root","group-child","group-leaf","host-two"),rows.map{it.id})
    }
}
