/**
 * Copyright (c) 2014-2016, FinancialForce.com, inc
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *      this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright notice,
 *      this list of conditions and the following disclaimer in the documentation
 *      and/or other materials provided with the distribution.
 * - Neither the name of the FinancialForce.com, inc nor the names of its contributors
 *      may be used to endorse or promote products derived from this software without
 *      specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
public class fflib_ApexMocksUtils
{
	/**
	 * This is taken from https://gist.github.com/afawcett/8dbfc0e1d8c43c982881.
	 *
	 * This method works on the principle that serializing and deserialising child records is supported
	 *
	 *   System.assertEquals(1, ((List<Master__c>) 
	 *    JSON.deserialize(
	 *	    JSON.serialize(
	 *         [select Id, Name, 
	 *            (select Id, Name from Children__r) from Master__c]), List<Master__c>.class))
	 *               [0].Children__r.size());
	 *
	 * This method results internally in constructing this JSON, before deserialising it back into SObject's
	 *
	 *		[
	 *		    {
	 *		        "attributes": {
	 *		            "type": "Master__c",
	 *		            "url": "/services/data/v32.0/sobjects/Master__c/a0YG0000005Jn5uMAC"
	 *		        },
	 *		        "Name": "Fred",
	 *		        "Id": "a0YG0000005Jn5uMAC",
	 *		        "Children__r": {
	 *		            "totalSize": 1,
	 *		            "done": true,
	 *		            "records": [
	 *		                {
	 *		                    "attributes": {
	 *		                        "type": "Child__c",
	 *		                        "url": "/services/data/v32.0/sobjects/Child__c/a0ZG0000006JGPAMA4"
	 *		                    },
	 *		                    "Name": "Bob",
	 *		                    "Id": "a0ZG0000006JGPAMA4",
	 *		                    "Master__c": "a0YG0000005Jn5uMAC"
	 *		                }
	 *		            ]
	 *		        }
	 * 		]
	 */
	public static Object makeRelationship(Type parentsType, List<SObject> parents, SObjectField relationshipField, List<List<SObject>> children) {

		// Find out more about this relationship...
		String relationshipFieldName = relationshipField.getDescribe().getName();
		DescribeSObjectResult parentDescribe = parents.getSObjectType().getDescribe();
		return deserializeParentsAndChildren(parentsType, parentDescribe, relationshipField, parents, children);
	}

	/**
	 * Generic overload to makeRelationship. Enables creation of
	 * relationships in a loosely-coupled manner. 
	 */
	public static Object makeRelationship(
			String parentTypeName,
			String childTypeName,
			List<SObject> parents,
			String relationshipFieldName,
			List<List<SObject>> children) {

		// Find out more about this relationship...
		SObjectType parentType = getType(parentTypeName);
		SObjectField relationshipField = getField(childTypeName, relationshipFieldName);
		DescribeSObjectResult parentDescribe = parentType.getDescribe();
		Type parentsType = List<SObject>.class;
		return deserializeParentsAndChildren(parentsType, parentDescribe, relationshipField, parents, children);
	}

	/**
	 * Gives the ability to set test values on formula
	 * and other read-only fields of mock SObjects
	 */
	public static Object setReadOnlyFields(SObject objInstance, Type deserializeType, Map<SObjectField, Object> properties) {

		Map<String, Object> fieldNameMap = new Map<String, Object>();
		for (SObjectField field : properties.keySet()) {
			// Resolve the fieldNames from the FieldTokens
			fieldNameMap.put(field.getDescribe().getName(), properties.get(field));
		}
		return (SObject) setReadOnlyFields(objInstance, deserializeType, fieldNameMap);
	}

	/**
	 * Generic overload to setReadOnlyFields. Enables setting test
	 * values on read-only fields by their name
	 */
	public static Object setReadOnlyFields(SObject objInstance, Type deserializeType, Map<String, Object> properties) {

		Map<String, Object> mergedMap = new Map<String, Object>(objInstance.getPopulatedFieldsAsMap());
		// Merge the values from the properties map into the fields already set on the object
		mergedMap.putAll(properties);
		// Serialize the merged map, and then deserialize it as the desired object type.
		String jsonString = JSON.serializePretty(mergedMap);
		return (SObject) JSON.deserialize(jsonString, deserializeType);
	}

	/**
	 * Helper Methods
	 */
	private static Object deserializeParentsAndChildren(
		Type parentsType,
		DescribeSObjectResult parentDescribe,
		SObjectField relationshipField,
		List<SObject> parents,
		List<List<SObject>> children
	) {
		List<Schema.ChildRelationship> childRelationships = parentDescribe.getChildRelationships();

		String relationshipName = null;
		for(Schema.ChildRelationship childRelationship : childRelationships) {
			if(childRelationship.getField() == relationshipField) {
				relationshipName = childRelationship.getRelationshipName();
				break;
			}
		}

		// Stream the parsed JSON representation of the parent objects back out, injecting children as it goes
		JSONParser parentsParser = JSON.createParser(JSON.serialize(parents));
		JSONParser childrenParser = JSON.createParser(JSON.serialize(children));
		JSONGenerator combinedOutput = JSON.createGenerator(false);		
		streamTokens(parentsParser, combinedOutput, new InjectChildrenEventHandler(childrenParser, relationshipName, children) );

		// Derserialise back into SObject list complete with children
		return JSON.deserialize(combinedOutput.getAsString(), parentsType);
	}

	/**
	 * Monitors stream events for end of object for each SObject contained in the parent list
	 *   then injects the respective childs record list into the stream
	 */
	private class InjectChildrenEventHandler implements JSONParserEvents
	{
		private JSONParser childrenParser;
		private String relationshipName;
		private List<List<SObject>> children;
		private Integer childListIdx = 0;

		public InjectChildrenEventHandler(JSONParser childrenParser, String relationshipName, List<List<SObject>> children) {
			this.childrenParser = childrenParser;
			this.relationshipName = relationshipName;
			this.children = children;
			this.childrenParser.nextToken(); // Consume the outer array token
		}

		public void nextToken(JSONParser fromStream, Integer depth, JSONGenerator toStream) {
			// Inject children?
			JSONToken currentToken = fromStream.getCurrentToken();
			if(depth == 2 && currentToken == JSONToken.END_OBJECT ) {
				toStream.writeFieldName(relationshipName);
				toStream.writeStartObject();
				toStream.writeNumberField('totalSize', children[childListIdx].size());
				toStream.writeBooleanField('done', true);
				toStream.writeFieldName('records');
				streamTokens(childrenParser, toStream, null);
				toStream.writeEndObject();
				childListIdx++;
			}
		}
	}

	/**
	 * Utility function to stream tokens from a reader to a write, while providing a basic eventing model
	 */
	private static void streamTokens(JSONParser fromStream, JSONGenerator toStream, JSONParserEvents events)
	{
		Integer depth = 0;
		while (fromStream.nextToken() != null)
		{
			// Give event handler chance to inject
			if (events != null) {
				events.nextToken(fromStream, depth, toStream);
			}
				
			// Forward to output stream
			switch on fromStream.getCurrentToken() {
				when START_ARRAY {
					toStream.writeStartArray();
					depth++;
				}
				when START_OBJECT {
					toStream.writeStartObject();
					depth++;
				}
				when FIELD_NAME {
					toStream.writeFieldName(fromStream.getCurrentName());
				}
				when VALUE_STRING, VALUE_FALSE, VALUE_TRUE, VALUE_NUMBER_FLOAT, VALUE_NUMBER_INT {
					toStream.writeString(fromStream.getText());
				}
			    when VALUE_NULL {
					toStream.writeNull();
				}
				when END_OBJECT {
					toStream.writeEndObject();
					depth--;
				}
				when END_ARRAY {
					toStream.writeEndArray();
					depth--;
				}
			}
			// Don't continue to stream beyond the initial starting point
			if (depth == 0) 
				break;
		}
	}

	/**
	 * Basic event used during the above streaming
	 */
	private interface JSONParserEvents
	{
		void nextToken(JSONParser fromStream, Integer depth, JSONGenerator toStream);
	}

	/**
	 * Gets the SObjectType by name
	 */
	private static Schema.SObjectType getType(String typeName) {
		Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
		SObjectType sobjType = gd.get(typeName);
		if (sobjType == null) {
			throw new fflib_ApexMocks.ApexMocksException('SObject type not found: ' + typeName);
		}
		return sobjType;
	}

	/**
	 * Gets the SObjectField of an object by name
	 */
	private static Schema.SObjectField getField(String objectName, String fieldName) {

		SObjectType sobjType = getType(objectName);
		Map<String, Schema.SObjectField> objectFields = sobjType.getDescribe().fields.getMap();
		Schema.SObjectField sobjField = objectFields.get(fieldName);
		if (sobjField == null) {
			throw new fflib_ApexMocks.ApexMocksException('SObject field not found: ' + fieldName);
		}
		return sobjField;
	}
}